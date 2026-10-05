const std = @import("std");

const core = @import("core");

const Dialect = @import("Dialect.zig");
const json = @import("json.zig");
const testing = @import("testing.zig");
const Transport = @import("Transport.zig");

const Responses = @This();

gpa: std.mem.Allocator,
options: Options,
reply: Dialect.Reply,
incomplete_message: bool,
open_part: ?Part,
completed_item_ids: std.StringHashMapUnmanaged(void),
call_item_id: std.ArrayList(u8),
call_output_index: ?u64,
call_named: bool,

pub const Options = struct {
    account: []const u8,
    endpoint: []const u8,
    codex_account_id: []const u8 = "",
    switches: Switches = .{},
};

pub const Switches = struct {
    plain_reasoning: bool = false,
    require_parameters: bool = false,
};

const IdentifyOptions = struct {
    token: []const u8,
    codex_account_id: []const u8 = "",
};

const Stored = struct {
    id: []const u8,
    text: []const u8 = "",
    encrypted_content: []const u8 = "",
    raw_text: []const u8 = "",

    fn replayable(self: *const Stored, switches: *const Switches) bool {
        if (self.id.len == 0) return false;
        if (self.encrypted_content.len != 0) return true;
        return switches.plain_reasoning and (self.text.len != 0 or self.raw_text.len != 0);
    }
};

const Part = struct {
    kind: Kind,
    index: u64,

    const Kind = enum { summary, text };

    fn eql(self: Part, other: Part) bool {
        return self.kind == other.kind and self.index == other.index;
    }
};

const ItemStatus = enum { completed, incomplete };

const vtable: Dialect.VTable = .{
    .prepare = prepare,
    .failure = failure,
    .quota = quota,
    .reset = reset,
    .decode = decode,
    .finish = finish,
};

const Slot = struct {
    used: ?f64 = null,
    minutes: ?u32 = null,
    reset_seconds: ?u64 = null,

    fn window(self: *const Slot) ?core.Provider.Quota.Window {
        const used = self.used orelse return null;
        return .{
            .used_percent = used,
            .window_minutes = self.minutes,
            .reset_seconds = self.reset_seconds,
        };
    }
};

pub fn init(gpa: std.mem.Allocator, options: Options) Responses {
    return .{
        .gpa = gpa,
        .options = options,
        .reply = .{},
        .incomplete_message = false,
        .open_part = null,
        .completed_item_ids = .empty,
        .call_item_id = .empty,
        .call_output_index = null,
        .call_named = false,
    };
}

pub fn deinit(self: *Responses) void {
    self.clearItemIds();
    self.completed_item_ids.deinit(self.gpa);
    self.call_item_id.deinit(self.gpa);
    self.reply.deinit(self.gpa);
}

pub fn dialect(self: *Responses) Dialect {
    return .{ .ptr = self, .vtable = &vtable };
}

fn prepare(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
    token: []const u8,
) Dialect.Error!Transport.Request {
    const self: *Responses = @ptrCast(@alignCast(ptr));
    var prepared: Transport.Request = .{
        .url = self.options.endpoint,
        .headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
        .body = try self.body(arena, request),
    };
    try identify(arena, &prepared, &.{
        .token = token,
        .codex_account_id = self.options.codex_account_id,
    });
    return prepared;
}

pub fn identify(
    arena: std.mem.Allocator,
    request: *Transport.Request,
    options: *const IdentifyOptions,
) error{OutOfMemory}!void {
    request.authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{options.token});
    request.user_agent = Transport.client_name;
    if (options.codex_account_id.len == 0) return;
    request.headers = try std.mem.concat(arena, std.http.Header, &.{ request.headers, &.{
        .{ .name = "chatgpt-account-id", .value = options.codex_account_id },
        .{ .name = "originator", .value = Transport.client_name },
    } });
}

pub fn body(
    self: *const Responses,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    self.writeBody(arena, &out.writer, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBody(
    self: *const Responses,
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
    try stringify.objectField("instructions");
    try stringify.write(request.system);
    if (request.cache_key.len > 0) {
        try stringify.objectField("prompt_cache_key");
        try stringify.write(request.cache_key);
    }
    if (request.effort) |effort| {
        try stringify.objectField("reasoning");
        try stringify.write(.{ .effort = @tagName(effort), .summary = "auto" });
    }
    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        for (request.tools) |*tool| try writeTool(&stringify, tool);
        try stringify.endArray();
        try stringify.objectField("tool_choice");
        try stringify.write("auto");
        if (!self.options.switches.require_parameters) {
            try stringify.objectField("parallel_tool_calls");
            try stringify.write(true);
        }
    }
    try stringify.objectField("store");
    try stringify.write(false);
    if (!self.options.switches.plain_reasoning) {
        try stringify.objectField("include");
        try stringify.beginArray();
        try stringify.write("reasoning.encrypted_content");
        try stringify.endArray();
    }
    try stringify.objectField("input");
    try stringify.beginArray();
    for (request.items) |*item| try self.writeItem(arena, &stringify, item);
    try stringify.endArray();
    try stringify.objectField("stream");
    try stringify.write(true);
    if (self.options.switches.require_parameters) {
        try stringify.objectField("provider");
        try stringify.write(.{ .require_parameters = true });
    }
    try stringify.endObject();
}

fn writeItem(
    self: *const Responses,
    arena: std.mem.Allocator,
    stringify: *std.json.Stringify,
    item: *const core.Conversation.Item,
) !void {
    switch (item.*) {
        .message => |*message| try writeMessage(stringify, message),
        .reasoning => |*proof| {
            const account = self.options.account;
            const stored = (try Dialect.decodeProof(Stored, arena, account, proof)) orelse return;
            if (stored.replayable(&self.options.switches)) try writeReasoning(stringify, &stored);
        },
        .tool_call => |*call| try writeToolCall(stringify, call),
        .tool_result => |*result| try writeToolResult(arena, stringify, result),
    }
}

fn writeMessage(stringify: *std.json.Stringify, message: *const core.Conversation.Message) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("message");
    try stringify.objectField("role");
    try stringify.write(@tagName(message.role));
    try stringify.objectField("content");
    try stringify.beginArray();
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write(if (message.role == .user) "input_text" else "output_text");
    try stringify.objectField("text");
    try stringify.write(message.text);
    try stringify.endObject();
    try stringify.endArray();
    try stringify.endObject();
}

fn writeReasoning(stringify: *std.json.Stringify, stored: *const Stored) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("reasoning");
    try stringify.objectField("id");
    try stringify.write(stored.id);
    try stringify.objectField("summary");
    try stringify.beginArray();
    if (stored.text.len > 0) {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("summary_text");
        try stringify.objectField("text");
        try stringify.write(stored.text);
        try stringify.endObject();
    }
    try stringify.endArray();
    if (stored.encrypted_content.len != 0) {
        try stringify.objectField("encrypted_content");
        try stringify.write(stored.encrypted_content);
    } else if (stored.raw_text.len != 0) {
        try stringify.objectField("content");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("reasoning_text");
        try stringify.objectField("text");
        try stringify.write(stored.raw_text);
        try stringify.endObject();
        try stringify.endArray();
    }
    try stringify.endObject();
}

fn writeToolCall(stringify: *std.json.Stringify, call: *const core.Tool.Call) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("function_call");
    try stringify.objectField("call_id");
    try stringify.write(call.id);
    try stringify.objectField("name");
    try stringify.write(call.name);
    try stringify.objectField("arguments");
    try stringify.write(call.argumentsJson());
    try stringify.endObject();
}

fn writeToolResult(
    arena: std.mem.Allocator,
    stringify: *std.json.Stringify,
    result: *const core.Tool.Result,
) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("function_call_output");
    try stringify.objectField("call_id");
    try stringify.write(result.call_id);
    try stringify.objectField("output");
    if (result.output.hasFailure()) {
        try stringify.write(try std.fmt.allocPrint(arena, "Error: {s}", .{result.output.content}));
    } else {
        try stringify.write(result.output.content);
    }
    try stringify.endObject();
}

fn writeTool(stringify: *std.json.Stringify, tool: *const core.Tool) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("function");
    try stringify.objectField("name");
    try stringify.write(tool.name);
    try stringify.objectField("description");
    try stringify.write(tool.description);
    try stringify.objectField("strict");
    try stringify.write(false);
    try stringify.objectField("parameters");
    try json.writeParametersSchema(stringify, tool.parameters);
    try stringify.endObject();
}

fn failure(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    failed: *const Dialect.Failed,
) error{OutOfMemory}!core.Provider.Failure {
    _ = ptr;
    var parsed: Dialect.Failed.Parsed = .{};
    if (try json.parseObject(arena, failed.body)) |object| {
        const error_detail = json.object(object.getPtr("error")) orelse object;
        parsed = .{
            .reason = errorReason(error_detail),
            .retry_after_ms = resetHint(error_detail),
            .detail = try errorDescription(arena, object),
        };
    }
    return failed.failure(arena, &parsed);
}

fn quota(
    ptr: *anyopaque,
    headers: []const std.http.Header,
    now_seconds: i64,
) ?core.Provider.Quota {
    _ = ptr;
    _ = now_seconds;
    return parseQuota(headers);
}

fn reset(ptr: *anyopaque) void {
    const self: *Responses = @ptrCast(@alignCast(ptr));
    self.reply.reset();
    self.incomplete_message = false;
    self.open_part = null;
    self.clearItemIds();
    self.call_item_id.clearRetainingCapacity();
    self.call_output_index = null;
    self.call_named = false;
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

fn clearItemIds(self: *Responses) void {
    var ids = self.completed_item_ids.keyIterator();
    while (ids.next()) |id| self.gpa.free(id.*);
    self.completed_item_ids.clearRetainingCapacity();
}

fn decode(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    payload: []const u8,
    events: *Dialect.Events,
) error{OutOfMemory}!Dialect.Decoded {
    const self: *Responses = @ptrCast(@alignCast(ptr));
    if (std.mem.eql(u8, payload, "[DONE]")) return .done;
    const object = (try json.parseObject(arena, payload)) orelse return .ignored;
    const kind = json.string(object.getPtr("type")) orelse return .ignored;

    if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "response.failed")) {
        try events.append(arena, .{ .failed = try streamedFailure(arena, object) });
        return .progress;
    }
    if (std.mem.eql(u8, kind, "response.refusal.delta") or
        std.mem.eql(u8, kind, "response.refusal.done"))
    {
        self.reply.reject(.unsupported);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "response.created")) {
        if (json.object(object.getPtr("response"))) |response|
            try self.captureServedModel(response);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "response.output_item.done")) {
        try self.outputItem(arena, object, events);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "response.output_text.delta")) {
        const delta = json.string(object.getPtr("delta")) orelse return .progress;
        if (delta.len == 0) return .progress;
        self.open_part = null;
        try events.append(arena, .{ .text = delta });
        return .progress;
    }
    if (std.mem.eql(u8, kind, "response.reasoning_summary_text.delta")) {
        const delta = json.string(object.getPtr("delta")) orelse return .progress;
        return self.reasoningDelta(arena, events, .summary, summaryIndex(object), delta);
    }
    if (std.mem.eql(u8, kind, "response.reasoning_text.delta")) {
        const delta = json.string(object.getPtr("delta")) orelse return .progress;
        return self.reasoningDelta(arena, events, .text, contentIndex(object), delta);
    }
    if (std.mem.eql(u8, kind, "response.reasoning_summary_part.added"))
        return self.reasoningPartAdded(arena, object, events);
    if (std.mem.eql(u8, kind, "response.output_item.added"))
        return self.addedItem(arena, object, events);
    if (std.mem.eql(u8, kind, "response.function_call_arguments.delta"))
        return self.callArguments(arena, object, events);
    if (std.mem.eql(u8, kind, "response.reasoning_summary_text.done") or
        std.mem.eql(u8, kind, "response.reasoning_summary_part.done") or
        std.mem.eql(u8, kind, "response.reasoning_text.done") or
        std.mem.eql(u8, kind, "response.function_call_arguments.done"))
    {
        return .progress;
    }

    const maybe_stop_reason: ?core.Provider.Stop.Reason =
        if (std.mem.eql(u8, kind, "response.completed"))
            .complete
        else if (std.mem.eql(u8, kind, "response.incomplete"))
            .truncated
        else
            null;
    if (maybe_stop_reason) |stop_reason| {
        try self.terminal(arena, object, stop_reason, events);
        return .progress;
    }
    return if (std.mem.startsWith(u8, kind, "response.")) .progress else .ignored;
}

fn terminal(
    self: *Responses,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    reason: core.Provider.Stop.Reason,
    events: *Dialect.Events,
) error{OutOfMemory}!void {
    if (json.object(object.getPtr("response"))) |response| {
        try self.reconcileTerminalOutput(arena, response);
        try self.captureServedModel(response);
    } else {
        self.reply.reject(.invalid);
    }
    if (reason == .complete and self.incomplete_message) self.reply.reject(.invalid);
    if (completedUsage(object)) |usage| {
        mergeUsage(&self.reply.usage, usage);
        self.reply.usage.cost_usd = json.amountUsd(usage.getPtr("cost"));
        try events.append(arena, .{ .usage = self.reply.usage });
    }
    try self.reply.end(arena, events, reason);
}

fn captureServedModel(self: *Responses, response: *const std.json.ObjectMap) !void {
    const model_name = json.string(response.getPtr("model")) orelse return;
    try self.reply.serve(self.gpa, model_name);
}

fn itemStatus(item: *const std.json.ObjectMap) ?ItemStatus {
    const status_value = item.getPtr("status") orelse return .completed;
    const status = json.string(status_value) orelse return null;
    if (std.mem.eql(u8, status, "completed")) return .completed;
    if (std.mem.eql(u8, status, "incomplete")) return .incomplete;
    return null;
}

fn recordCompletedItem(self: *Responses, id: []const u8) !bool {
    if (id.len == 0) return false;
    const result = try self.completed_item_ids.getOrPut(self.gpa, id);
    if (result.found_existing) return false;
    errdefer _ = self.completed_item_ids.remove(id);
    result.key_ptr.* = try self.gpa.dupe(u8, id);
    return true;
}

fn markTerminalItemRejection(self: *Responses, item: *const std.json.ObjectMap) void {
    const kind = json.string(item.getPtr("type")) orelse return self.reply.reject(.invalid);
    if (std.mem.eql(u8, kind, "reasoning") or
        std.mem.eql(u8, kind, "function_call")) return;
    if (!std.mem.eql(u8, kind, "message")) return self.reply.reject(.unsupported);
    const content = json.array(item.getPtr("content")) orelse return self.reply.reject(.invalid);
    for (content.items) |*value| {
        const part = json.object(value) orelse return self.reply.reject(.invalid);
        const part_kind = json.string(part.getPtr("type")) orelse
            return self.reply.reject(.invalid);
        if (!std.mem.eql(u8, part_kind, "output_text")) return self.reply.reject(.unsupported);
    }
}

fn reconcileTerminalOutput(
    self: *Responses,
    arena: std.mem.Allocator,
    response: *const std.json.ObjectMap,
) !void {
    const output_value = response.getPtr("output") orelse return;
    const output = json.array(output_value) orelse {
        self.reply.reject(.invalid);
        return;
    };
    if (output.items.len == 0) return;
    var terminal_ids: std.StringHashMapUnmanaged(void) = .empty;
    for (output.items) |*value| {
        const item = json.object(value) orelse {
            self.reply.reject(.invalid);
            continue;
        };
        self.markTerminalItemRejection(item);
        const id = json.string(item.getPtr("id")) orelse {
            self.reply.reject(.invalid);
            continue;
        };
        const result = try terminal_ids.getOrPut(arena, id);
        if (result.found_existing) {
            self.reply.reject(.invalid);
            continue;
        }
        if (!self.completed_item_ids.contains(id)) self.reply.reject(.invalid);
    }
    if (terminal_ids.count() != self.completed_item_ids.count()) self.reply.reject(.invalid);
}

fn joinedReasoning(
    arena: std.mem.Allocator,
    item: *const std.json.ObjectMap,
    options: *const struct { field: []const u8, part_type: []const u8 },
) !?[]const u8 {
    const parts_value = item.getPtr(options.field) orelse return "";
    if (parts_value.* == .null) return "";
    const parts = json.array(parts_value) orelse return null;
    var text: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |*value, index| {
        const part = json.object(value) orelse return null;
        const kind = json.string(part.getPtr("type")) orelse return null;
        if (!std.mem.eql(u8, kind, options.part_type)) return null;
        const part_text = json.string(part.getPtr("text")) orelse return null;
        if (index != 0) try text.appendSlice(arena, "\n\n");
        try text.appendSlice(arena, part_text);
    }
    return text.items;
}

fn outputItem(
    self: *Responses,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) !void {
    const reply = &self.reply;
    const item = json.object(object.getPtr("item")) orelse return reply.reject(.invalid);
    const item_kind = json.string(item.getPtr("type")) orelse return reply.reject(.invalid);
    const id = json.string(item.getPtr("id")) orelse return reply.reject(.invalid);
    const status = itemStatus(item) orelse return reply.reject(.invalid);
    if (!try self.recordCompletedItem(id)) return reply.reject(.invalid);

    if (std.mem.eql(u8, item_kind, "message")) {
        if (item.getPtr("role")) |role_value| {
            const role = json.string(role_value) orelse return reply.reject(.invalid);
            if (!std.mem.eql(u8, role, "assistant")) return reply.reject(.invalid);
        }
        const content = json.array(item.getPtr("content")) orelse return reply.reject(.invalid);
        var text: std.ArrayList(u8) = .empty;
        for (content.items) |*value| {
            const part = json.object(value) orelse return reply.reject(.invalid);
            const part_kind = json.string(part.getPtr("type")) orelse return reply.reject(.invalid);
            if (!std.mem.eql(u8, part_kind, "output_text")) return reply.reject(.unsupported);
            const part_text = json.string(part.getPtr("text")) orelse return reply.reject(.invalid);
            try text.appendSlice(arena, part_text);
        }
        if (text.items.len == 0) return reply.reject(.invalid);
        if (status == .incomplete) self.incomplete_message = true;
        try events.append(arena, .{ .output = .{ .message = text.items } });
        return;
    }
    if (std.mem.eql(u8, item_kind, "reasoning")) {
        self.open_part = null;
        if (status != .completed) return reply.reject(.invalid);
        const encrypted_value = item.getPtr("encrypted_content") orelse
            &@as(std.json.Value, .null);
        const encrypted_content = if (encrypted_value.* == .null)
            ""
        else
            json.string(encrypted_value) orelse return reply.reject(.invalid);
        const text = try joinedReasoning(arena, item, &.{
            .field = "summary",
            .part_type = "summary_text",
        }) orelse return reply.reject(.invalid);
        const raw_text = try joinedReasoning(arena, item, &.{
            .field = "content",
            .part_type = "reasoning_text",
        }) orelse return reply.reject(.invalid);
        const stored: Stored = .{
            .id = id,
            .text = text,
            .encrypted_content = encrypted_content,
            .raw_text = raw_text,
        };
        if (!stored.replayable(&self.options.switches)) {
            if (!self.options.switches.plain_reasoning) reply.reject(.invalid);
            return;
        }
        const account = self.options.account;
        const proof = try Dialect.encodeProof(Stored, arena, account, &stored);
        try events.append(arena, .{ .output = .{ .reasoning = proof } });
        return;
    }
    if (std.mem.eql(u8, item_kind, "function_call")) {
        self.call_item_id.clearRetainingCapacity();
        self.call_output_index = null;
        self.call_named = false;
        if (status != .completed) return reply.reject(.invalid);
        const call_id = json.string(item.getPtr("call_id")) orelse return reply.reject(.invalid);
        const name = json.string(item.getPtr("name")) orelse return reply.reject(.invalid);
        const arguments = json.string(item.getPtr("arguments")) orelse
            return reply.reject(.invalid);
        if (call_id.len == 0) return reply.reject(.invalid);
        try events.append(arena, .{ .output = .{ .tool_call = .{
            .id = call_id,
            .name = name,
            .arguments = arguments,
        } } });
        return;
    }
    return reply.reject(.unsupported);
}

fn reasoningDelta(
    self: *Responses,
    arena: std.mem.Allocator,
    events: *Dialect.Events,
    kind: Part.Kind,
    maybe_index: ?u64,
    delta: []const u8,
) error{OutOfMemory}!Dialect.Decoded {
    if (delta.len == 0) return .progress;
    const index = maybe_index orelse if (self.open_part) |open| open.index else 0;
    const part: Part = .{ .kind = kind, .index = index };
    if (self.open_part == null or !self.open_part.?.eql(part)) {
        self.open_part = part;
        try events.append(arena, .reasoning_started);
    }
    try events.append(arena, .{ .reasoning = delta });
    return .progress;
}

fn reasoningPartAdded(
    self: *Responses,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) error{OutOfMemory}!Dialect.Decoded {
    const index = summaryIndex(object) orelse return .progress;
    const part = json.object(object.getPtr("part")) orelse return .progress;
    const kind = json.string(part.getPtr("type")) orelse return .progress;
    if (!std.mem.eql(u8, kind, "summary_text")) return .progress;
    const text = json.string(part.getPtr("text")) orelse return .progress;
    return self.reasoningDelta(arena, events, .summary, index, text);
}

fn summaryIndex(object: *const std.json.ObjectMap) ?u64 {
    return json.unsigned(object.getPtr("summary_index"));
}

fn contentIndex(object: *const std.json.ObjectMap) ?u64 {
    return json.unsigned(object.getPtr("content_index"));
}

fn outputIndex(object: *const std.json.ObjectMap) ?u64 {
    return json.unsigned(object.getPtr("output_index"));
}

fn addedItem(
    self: *Responses,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) !Dialect.Decoded {
    self.open_part = null;
    const item = json.object(object.getPtr("item")) orelse return .progress;
    const kind = json.string(item.getPtr("type")) orelse return .progress;
    if (!std.mem.eql(u8, kind, "function_call")) return .progress;

    self.call_item_id.clearRetainingCapacity();
    if (json.string(item.getPtr("id"))) |id| try self.call_item_id.appendSlice(self.gpa, id);
    self.call_output_index = outputIndex(object);

    const name = json.string(item.getPtr("name")) orelse {
        self.call_named = false;
        return .progress;
    };
    self.call_named = true;
    try events.append(arena, .{ .tool_call_started = name });
    return .progress;
}

fn callArguments(
    self: *Responses,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) error{OutOfMemory}!Dialect.Decoded {
    var matched = false;
    const open_id = self.call_item_id.items;
    if (json.string(object.getPtr("item_id"))) |item_id| {
        if (open_id.len != 0) {
            if (!std.mem.eql(u8, item_id, open_id)) {
                self.reply.reject(.uncorrelated);
                return .progress;
            }
            matched = true;
        }
    }
    if (outputIndex(object)) |index| {
        if (self.call_output_index) |open_index| {
            if (index != open_index) {
                self.reply.reject(.uncorrelated);
                return .progress;
            }
            matched = true;
        }
    }
    if (!matched or !self.call_named) return .progress;
    const delta = json.string(object.getPtr("delta")) orelse return .progress;
    try events.append(arena, .{ .tool_call_arguments = delta });
    return .progress;
}

fn streamedFailure(
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
) error{OutOfMemory}!core.Provider.Failure {
    const detail = errorDetail(object);
    return .{
        .reason = errorReason(detail) orelse .invalid_request,
        .retry_after_ms = resetHint(detail),
        .message = (try errorDescription(arena, object)) orelse "",
    };
}

fn errorDetail(object: *const std.json.ObjectMap) *const std.json.ObjectMap {
    if (json.object(object.getPtr("error"))) |detail| return detail;
    if (json.object(object.getPtr("response"))) |response| {
        if (json.object(response.getPtr("error"))) |detail| return detail;
    }
    return object;
}

fn errorReason(detail: *const std.json.ObjectMap) ?core.Provider.Failure.Reason {
    if (json.string(detail.getPtr("type"))) |kind| {
        if (std.mem.eql(u8, kind, "usage_limit_reached")) return .quota_exhausted;
    }
    const code = json.string(detail.getPtr("code")) orelse return null;
    if (std.mem.eql(u8, code, "server_error")) return .overloaded;
    if (std.mem.eql(u8, code, "rate_limit_exceeded")) return .rate_limited;
    if (std.mem.eql(u8, code, "insufficient_quota")) return .quota_exhausted;
    if (std.mem.eql(u8, code, "context_length_exceeded")) return .context_overflow;
    return null;
}

fn resetHint(detail: *const std.json.ObjectMap) ?u64 {
    const seconds = json.unsigned(detail.getPtr("resets_in_seconds")) orelse return null;
    return seconds *| 1000;
}

fn completedUsage(object: *const std.json.ObjectMap) ?*const std.json.ObjectMap {
    const response = json.object(object.getPtr("response")) orelse return null;
    return json.object(response.getPtr("usage"));
}

fn errorMessage(object: *const std.json.ObjectMap) ?[]const u8 {
    if (json.string(object.getPtr("message"))) |message| return message;
    if (json.object(object.getPtr("error"))) |detail| {
        if (json.string(detail.getPtr("message"))) |message| return message;
    }
    if (json.string(object.getPtr("error"))) |message| return message;
    if (json.object(object.getPtr("response"))) |response| {
        if (json.object(response.getPtr("error"))) |detail|
            return json.string(detail.getPtr("message"));
    }
    return null;
}

fn upstreamText(arena: std.mem.Allocator, detail: *const std.json.ObjectMap) !?[]const u8 {
    const metadata = json.object(detail.getPtr("metadata")) orelse return null;
    const raw = metadata.getPtr("raw") orelse return null;
    if (json.object(raw)) |body_object| return errorMessage(body_object);
    const text = json.string(raw) orelse return null;
    if (text.len == 0) return null;
    const body_object = (try json.parseObject(arena, text)) orelse return text;
    return errorMessage(body_object) orelse text;
}

fn errorDescription(arena: std.mem.Allocator, object: *const std.json.ObjectMap) !?[]const u8 {
    const detail = json.object(object.getPtr("error")) orelse object;
    if (try usageLimitText(arena, detail)) |text| return text;
    if (try upstreamText(arena, detail)) |text| return text;
    return errorMessage(object);
}

fn usageLimitText(arena: std.mem.Allocator, detail: *const std.json.ObjectMap) !?[]const u8 {
    const kind = json.string(detail.getPtr("type")) orelse return null;
    if (!std.mem.eql(u8, kind, "usage_limit_reached")) return null;
    const plan = json.string(detail.getPtr("plan_type")) orelse "";
    const subject = if (plan.len == 0)
        "The subscription"
    else
        try std.fmt.allocPrint(arena, "The {c}{s} plan", .{
            std.ascii.toUpper(plan[0]),
            plan[1..],
        });
    const maybe_seconds = json.unsigned(detail.getPtr("resets_in_seconds"));
    const reset_text = if (maybe_seconds) |seconds|
        try std.fmt.allocPrint(arena, " It resets in {s}.", .{try resetText(arena, seconds)})
    else
        "";
    return try std.fmt.allocPrint(
        arena,
        "{s} reached its usage limit.{s}",
        .{ subject, reset_text },
    );
}

fn resetText(arena: std.mem.Allocator, seconds: u64) ![]const u8 {
    const minutes = @divFloor(seconds, 60);
    const hours = @divFloor(minutes, 60);
    const days = @divFloor(hours, 24);
    if (minutes == 0) return "less than a minute";
    if (hours == 0) return std.fmt.allocPrint(arena, "{d} minute{s}", .{
        minutes,
        core.text.pluralSuffix(minutes),
    });
    if (days == 0) {
        const rest_minutes = minutes - hours * 60;
        if (rest_minutes == 0) return std.fmt.allocPrint(arena, "{d} hour{s}", .{
            hours,
            core.text.pluralSuffix(hours),
        });
        return std.fmt.allocPrint(arena, "{d} hour{s} {d} minute{s}", .{
            hours,
            core.text.pluralSuffix(hours),
            rest_minutes,
            core.text.pluralSuffix(rest_minutes),
        });
    }
    const rest_hours = hours - days * 24;
    if (rest_hours == 0)
        return std.fmt.allocPrint(arena, "{d} day{s}", .{ days, core.text.pluralSuffix(days) });
    return std.fmt.allocPrint(arena, "{d} day{s} {d} hour{s}", .{
        days,
        core.text.pluralSuffix(days),
        rest_hours,
        core.text.pluralSuffix(rest_hours),
    });
}

fn mergeUsage(usage: *core.Provider.Usage, object: *const std.json.ObjectMap) void {
    const total_input = json.unsigned(object.getPtr("input_tokens")) orelse 0;
    var cached: u64 = 0;
    var written: u64 = 0;
    if (json.object(object.getPtr("input_tokens_details"))) |details| {
        cached = json.unsigned(details.getPtr("cached_tokens")) orelse 0;
        written = json.unsigned(details.getPtr("cache_write_tokens")) orelse 0;
    }
    usage.cache_read = cached;
    usage.cache_write = written;
    usage.input = total_input -| cached -| written;
    if (json.unsigned(object.getPtr("output_tokens"))) |value| usage.output = value;
}

fn parseQuota(headers: []const std.http.Header) ?core.Provider.Quota {
    var primary: Slot = .{};
    var secondary: Slot = .{};
    for (headers) |header| {
        const value = std.mem.trim(u8, header.value, " \t");
        if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-used-percent")) {
            primary.used = parseQuotaPercent(value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-window-minutes")) {
            primary.minutes = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-reset-after-seconds")) {
            primary.reset_seconds = parseResetSeconds(value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-secondary-used-percent")) {
            secondary.used = parseQuotaPercent(value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-secondary-window-minutes")) {
            secondary.minutes = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-secondary-reset-after-seconds")) {
            secondary.reset_seconds = parseResetSeconds(value);
        }
    }
    if (primary.used == null and secondary.used == null) return null;
    return .{ .primary = primary.window(), .secondary = secondary.window() };
}

fn parseResetSeconds(value: []const u8) ?u64 {
    const seconds = std.fmt.parseInt(u64, value, 10) catch return null;
    return if (seconds == 0) null else seconds;
}

fn parseQuotaPercent(value: []const u8) ?f64 {
    const percent = std.fmt.parseFloat(f64, value) catch return null;
    return core.Provider.Quota.Window.usedPercent(percent);
}

test "the body names the model, the instructions, the effort, the tools, and the input" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "hi \"there\"" } },
    };
    var request = testRequest(&items, .high);
    request.tools = &testing.tools;
    const parsed = try Rig.body(test_options, &request);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-5.6-sol", root.get("model").?.string);
    try std.testing.expectEqualStrings("be terse", root.get("instructions").?.string);
    try std.testing.expectEqual(false, root.get("store").?.bool);
    try std.testing.expectEqual(true, root.get("stream").?.bool);
    try std.testing.expect(root.get("max_output_tokens") == null);
    const reasoning = root.get("reasoning").?.object;
    try std.testing.expectEqualStrings("high", reasoning.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", reasoning.get("summary").?.string);
    try std.testing.expectEqualStrings(
        "reasoning.encrypted_content",
        root.get("include").?.array.items[0].string,
    );
    try std.testing.expect(root.get("prompt_cache_key") == null);

    const message = root.get("input").?.array.items[0].object;
    try std.testing.expectEqualStrings("message", message.get("type").?.string);
    try std.testing.expectEqualStrings("user", message.get("role").?.string);
    const content = message.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("input_text", content.get("type").?.string);
    try std.testing.expectEqualStrings("hi \"there\"", content.get("text").?.string);

    const tool = root.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("function", tool.get("type").?.string);
    try std.testing.expectEqualStrings("read", tool.get("name").?.string);
    try std.testing.expectEqual(false, tool.get("strict").?.bool);
    const schema = tool.get("parameters").?.object;
    try std.testing.expectEqualStrings("object", schema.get("type").?.string);
    try std.testing.expectEqualStrings(
        "string",
        schema.get("properties").?.object.get("path").?.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings("path", schema.get("required").?.array.items[0].string);
    try std.testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    try std.testing.expect(root.get("parallel_tool_calls").?.bool);
}

const test_options: Options = .{
    .account = "openai-api-key",
    .endpoint = "https://api.openai.com/v1/responses",
};

fn proofItem(account: []const u8, stored: *const Stored) !core.Conversation.Item {
    const payload = try std.json.Stringify.valueAlloc(std.testing.allocator, stored.*, .{});
    return .{ .reasoning = .{ .account = account, .payload = payload } };
}

fn freeProofs(items: []const core.Conversation.Item) void {
    for (items) |item| if (item == .reasoning) std.testing.allocator.free(item.reasoning.payload);
}

const Rig = testing.DialectRig(Responses);

fn testRequest(
    items: []const core.Conversation.Item,
    effort: ?core.Provider.Effort,
) core.Provider.Request {
    return .{
        .model = "gpt-5.6-sol",
        .tokens_max = 8192,
        .system = "be terse",
        .items = items,
        .tools = &.{},
        .effort = effort,
        .cache_key = "",
    };
}

test "the cache key goes out when the request holds one, and no effort sends no reasoning" {
    const items = [_]core.Conversation.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    var request = testRequest(&items, null);
    request.cache_key = "session-abc";
    const parsed = try Rig.body(test_options, &request);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "session-abc",
        parsed.value.object.get("prompt_cache_key").?.string,
    );
    try std.testing.expect(parsed.value.object.get("reasoning") == null);
    const content = parsed.value.object.get("input").?.array.items[0].object
        .get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("input_text", content.get("type").?.string);
}

test "tool call arguments go out as a JSON string and a failed result takes the Error prefix" {
    var failed: core.Tool.Output = .{ .content = "boom" };
    failed.conditions.insert(.failed);
    var noted: core.Tool.Output = .{ .content = "ok" };
    noted.conditions.insert(.line_truncated);
    const items = [_]core.Conversation.Item{
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .tool_call = .{ .id = "call_2", .name = "list", .arguments = "" } },
        .{ .tool_result = .{ .call_id = "call_1", .output = failed } },
        .{ .tool_result = .{ .call_id = "call_2", .output = noted } },
        .{ .message = .{ .role = .assistant, .text = "prior turn" } },
    };
    const parsed = try Rig.body(test_options, &testRequest(&items, null));
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqualStrings("function_call", input[0].object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "{\"path\":\"a.zig\"}",
        input[0].object.get("arguments").?.string,
    );
    try std.testing.expectEqualStrings("{}", input[1].object.get("arguments").?.string);
    try std.testing.expectEqualStrings(
        "function_call_output",
        input[2].object.get("type").?.string,
    );
    try std.testing.expectEqualStrings("Error: boom", input[2].object.get("output").?.string);
    try std.testing.expectEqualStrings("ok", input[3].object.get("output").?.string);
    const content = input[4].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("output_text", content.get("type").?.string);
}

test "the body replays only the complete proof of its own account" {
    const items = [_]core.Conversation.Item{
        try proofItem("openai-plan", &.{
            .id = "rs_1",
            .text = "weigh it",
            .encrypted_content = "enc",
        }),
        try proofItem("openai-api-key", &.{
            .id = "rs_other",
            .text = "foreign",
            .encrypted_content = "other",
        }),
        try proofItem("openai-plan", &.{ .id = "rs_2", .text = "no blob" }),
        .{ .reasoning = .{
            .account = "openai-plan",
            .payload = try std.testing.allocator.dupe(u8, "not json"),
        } },
        .{ .message = .{ .role = .assistant, .text = "done" } },
    };
    defer freeProofs(&items);
    const parsed = try Rig.body(
        .{ .account = "openai-plan", .endpoint = "e" },
        &testRequest(&items, null),
    );
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expectEqualStrings("reasoning", input[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("rs_1", input[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("enc", input[0].object.get("encrypted_content").?.string);
    try std.testing.expectEqualStrings(
        "weigh it",
        input[0].object.get("summary").?.array.items[0].object.get("text").?.string,
    );
    try std.testing.expectEqualStrings("message", input[1].object.get("type").?.string);
}

const golden_items = [_]core.Conversation.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .reasoning = .{
        .account = "openai-api-key",
        .payload = "{\"id\":\"rs_1\",\"text\":\"think\",\"encrypted_content\":\"enc1\"}",
    } },
    .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "call_1", .output = .{ .content = "contents" } } },
    .{ .reasoning = .{
        .account = "openai-api-key",
        .payload = "{\"id\":\"rs_2\",\"encrypted_content\":\"enc2\"}",
    } },
    .{ .tool_call = .{ .id = "call_2", .name = "write", .arguments = "{\"path\":\"b\"}" } },
    .{ .tool_result = .{ .call_id = "call_2", .output = .{
        .content = "denied",
        .conditions = .initOne(.failed),
    } } },
    .{ .reasoning = .{
        .account = "openai-plan",
        .payload = "{\"id\":\"rs_3\",\"text\":\"foreign\",\"encrypted_content\":\"enc3\"}",
    } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden = testing.oneLine(
    \\{"model":"gpt-5.6-sol","instructions":"be terse","reasoning":{"effort":"xhigh",
    \\"summary":"auto"},"tools":[{"type":"function","name":"read","description":"read a file",
    \\"strict":false,"parameters":{"type":"object","properties":{"path":{"type":"string",
    \\"description":"the path"}},"required":["path"],"additionalProperties":false}}],
    \\"tool_choice":"auto","parallel_tool_calls":true,"store":false,
    \\"include":["reasoning.encrypted_content"],"input":[{"type":"message","role":"user",
    \\"content":[{"type":"input_text","text":"first"}]},{"type":"reasoning","id":"rs_1",
    \\"summary":[{"type":"summary_text","text":"think"}],"encrypted_content":"enc1"},
    \\{"type":"function_call","call_id":"call_1","name":"read","arguments":"{\"path\":\"a.zig\"}"},
    \\{"type":"message","role":"assistant","content":[{"type":"output_text","text":"checking"}]},
    \\{"type":"function_call_output","call_id":"call_1","output":"contents"},{"type":"reasoning",
    \\"id":"rs_2","summary":[],"encrypted_content":"enc2"},{"type":"function_call",
    \\"call_id":"call_2","name":"write","arguments":"{\"path\":\"b\"}"},
    \\{"type":"function_call_output","call_id":"call_2","output":"Error: denied"},{"type":"message",
    \\"role":"assistant","content":[{"type":"output_text","text":"all set"}]}],"stream":true}
);

test "the golden bytes keep the Responses wire shape stable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const responses: Responses = .init(std.testing.allocator, test_options);
    var request = testRequest(&golden_items, .xhigh);
    request.tools = &testing.tools;
    const bytes = try responses.body(arena.allocator(), &request);
    try std.testing.expectEqualStrings(golden, bytes);
}

test "a routed request requires its parameters and replays plain reasoning" {
    const items = [_]core.Conversation.Item{
        try proofItem("openrouter-api-key", &.{
            .id = "rs_or",
            .text = "think",
            .encrypted_content = "enc",
            .raw_text = "raw reasoning",
        }),
        try proofItem("openrouter-api", &.{
            .id = "rs_foreign",
            .text = "foreign summary",
            .raw_text = "foreign reasoning",
        }),
        try proofItem("openrouter-api-key", &.{ .id = "rs_plain", .raw_text = "plain reasoning" }),
    };
    defer freeProofs(&items);
    var request = testRequest(&items, null);
    request.tools = &testing.tools;
    const parsed = try Rig.body(.{
        .account = "openrouter-api-key",
        .endpoint = "e",
        .switches = .{ .plain_reasoning = true, .require_parameters = true },
    }, &request);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("provider").?.object.get("require_parameters").?.bool);
    try std.testing.expect(root.get("include") == null);
    try std.testing.expect(root.get("parallel_tool_calls") == null);
    try std.testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    const input = root.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expectEqualStrings("rs_or", input[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("enc", input[0].object.get("encrypted_content").?.string);
    try std.testing.expect(input[0].object.get("content") == null);
    try std.testing.expectEqualStrings("rs_plain", input[1].object.get("id").?.string);
    try std.testing.expect(input[1].object.get("encrypted_content") == null);
    const plain_part = input[1].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("reasoning_text", plain_part.get("type").?.string);
    try std.testing.expectEqualStrings("plain reasoning", plain_part.get("text").?.string);

    const strict = try Rig.body(.{ .account = "openrouter-api-key", .endpoint = "e" }, &request);
    defer strict.deinit();
    try std.testing.expect(strict.value.object.get("parallel_tool_calls").?.bool);
    try std.testing.expect(strict.value.object.get("provider") == null);
    try std.testing.expectEqualStrings(
        "reasoning.encrypted_content",
        strict.value.object.get("include").?.array.items[0].string,
    );
    try std.testing.expectEqual(@as(usize, 1), strict.value.object.get("input").?.array.items.len);
}

test "prepare sends the bearer token, the event-stream accept, and the Codex identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const request = testRequest(&.{}, null);
    var codex: Responses = .init(std.testing.allocator, .{
        .account = "openai-plan",
        .endpoint = "https://chatgpt.com/backend-api/codex/responses",
        .codex_account_id = "acct-1234",
    });
    const prepared = try codex.dialect().prepare(arena.allocator(), &request, "secret-token");
    try std.testing.expectEqualStrings(
        "https://chatgpt.com/backend-api/codex/responses",
        prepared.url,
    );
    try std.testing.expectEqualStrings("Bearer secret-token", prepared.authorization.?);
    try std.testing.expectEqualStrings(Transport.client_name, prepared.user_agent.?);
    try std.testing.expectEqual(@as(usize, 3), prepared.headers.len);
    try std.testing.expectEqualStrings("accept", prepared.headers[0].name);
    try std.testing.expectEqualStrings("text/event-stream", prepared.headers[0].value);
    try std.testing.expectEqualStrings("chatgpt-account-id", prepared.headers[1].name);
    try std.testing.expectEqualStrings("acct-1234", prepared.headers[1].value);
    try std.testing.expectEqualStrings("originator", prepared.headers[2].name);
    try std.testing.expectEqualStrings(Transport.client_name, prepared.headers[2].value);
    try std.testing.expect(std.mem.startsWith(u8, prepared.body, "{\"model\":\"gpt-5.6-sol\""));
}

test "an empty terminal output snapshot does not reject the streamed reply" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"id":"msg_1","type":"message",
        \\"status":"completed","content":[{"type":"output_text","text":"Hello!"}],
        \\"role":"assistant"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","output":[],
        \\"usage":{"input_tokens":5,"output_tokens":2}}}
        ,
    });
    try rig.frames.expect(
        \\message:Hello!
        \\usage:5/2/0/0
        \\stopped:complete|
        \\
    );
}

test "the terminal response names the model that served the reply" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try std.testing.expectEqual(Dialect.Decoded.progress, try rig.frames.decode(
        \\{"type":"response.created","response":{"model":"gpt-5.6-luna"}}
    ));
    try rig.frames.feed(&.{
        \\{"type":"response.completed","response":{"status":"completed"}}
    });
    try rig.frames.expect("stopped:complete|gpt-5.6-luna\n");

    var renamed: Rig = undefined;
    renamed.init(test_options);
    defer renamed.deinit();
    try renamed.frames.feed(&.{
        \\{"type":"response.created","response":{"model":"gpt-5.6-sol"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","model":"gpt-5.6-terra"}}
        ,
    });
    try renamed.frames.expect("stopped:complete|gpt-5.6-terra\n");

    var unnamed: Rig = undefined;
    unnamed.init(test_options);
    defer unnamed.deinit();
    try unnamed.frames.feed(&.{
        \\{"type":"response.completed","response":{"status":"completed"}}
    });
    try unnamed.frames.expect("stopped:complete|\n");
}

test "display deltas and completed messages stay separate, and parts join without a separator" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"hello "}
        ,
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":""}
        ,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1",
        \\"role":"assistant","status":"completed","content":[{"type":"output_text","text":"hello "},
        \\{"type":"output_text","text":"world"}]}}
        ,
    });
    try rig.frames.expect(
        \\text:hello 
        \\message:hello world
        \\
    );
}

test "an incomplete message survives only an incomplete terminal response" {
    var truncated: Rig = undefined;
    truncated.init(test_options);
    defer truncated.deinit();
    try truncated.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1",
        \\"role":"assistant","status":"incomplete","content":[{"type":"output_text",
        \\"text":"partial"}]}}
        ,
        \\{"type":"response.incomplete","response":{"status":"incomplete"}}
        ,
    });
    try truncated.frames.expect(
        \\message:partial
        \\stopped:truncated|
        \\
    );

    var completed: Rig = undefined;
    completed.init(test_options);
    defer completed.deinit();
    try completed.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_2",
        \\"role":"assistant","status":"incomplete","content":[{"type":"output_text",
        \\"text":"partial"}]}}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try completed.frames.expect(
        \\message:partial
        \\failed:invalid_reply|-|
        \\
    );
}

test "done items are authoritative and a duplicate id latches invalid" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message",
        \\"id":"provisional"}}
        ,
        \\{"type":"response.output_item.done","output_index":1,"item":{"type":"message",
        \\"id":"authoritative","role":"assistant","status":"completed",
        \\"content":[{"type":"output_text","text":"done"}]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"authoritative",
        \\"role":"assistant","content":[{"type":"output_text","text":"twice"}]}}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try rig.frames.expect(
        \\message:done
        \\failed:invalid_reply|-|
        \\
    );
}

test "an unsupported completed item rejects the whole reply with its usage" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1",
        \\"role":"assistant","content":[{"type":"output_text","text":"recognized"}]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"web_search_call","id":"search_1",
        \\"status":"completed"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed",
        \\"usage":{"output_tokens":4}}}
        ,
    });
    try rig.frames.expect(
        \\message:recognized
        \\usage:0/4/0/0
        \\failed:unsupported_reply|-|The reply holds content that Drinky cannot keep.
        \\
    );
}

test "the terminal output snapshot must match the done-item set" {
    var missing: Rig = undefined;
    missing.init(test_options);
    defer missing.deinit();
    try missing.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1",
        \\"role":"assistant","content":[{"type":"output_text","text":"one"}]}}
        ,
        \\{"type":"response.completed","response":{"status":"completed","output":[{"type":"message",
        \\"id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"one"}]},
        \\{"type":"message","id":"msg_2","role":"assistant","content":[{"type":"output_text",
        \\"text":"two"}]}]}}
        ,
    });
    try missing.frames.expect(
        \\message:one
        \\failed:invalid_reply|-|
        \\
    );

    var unsupported: Rig = undefined;
    unsupported.init(test_options);
    defer unsupported.deinit();
    try unsupported.frames.feed(&.{
        \\{"type":"response.completed","response":{"status":"completed",
        \\"output":[{"type":"web_search_call","id":"search_1","status":"completed"}]}}
    });
    try unsupported.frames.expect(
        \\failed:unsupported_reply|-|The reply holds content that Drinky cannot keep.
        \\
    );
}

test "reasoning parts stream with a start each, and the done item carries the proof" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,
        \\"delta":"a"}
        ,
        \\{"type":"response.reasoning_summary_part.added","item_id":"rs_1","summary_index":1,
        \\"part":{"type":"summary_text","text":""}}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,
        \\"delta":"b"}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,
        \\"delta":"c"}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"status":"completed","summary":[{"type":"summary_text","text":"x"},
        \\{"type":"summary_text","text":"y"}],"encrypted_content":"enc"}}
        ,
    });
    try rig.frames.expect(
        \\reasoning_started
        \\reasoning:a
        \\reasoning_started
        \\reasoning:b
        \\reasoning:c
        \\proof:openai-api-key:{"id":"rs_1","text":"x\n\ny","encrypted_content":"enc","raw_text":""}
        \\
    );
}

test "raw reasoning text deltas stream like summary deltas" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.reasoning_text.delta","item_id":"rs_1","output_index":0,
        \\"content_index":0,"delta":"think"}
        ,
        \\{"type":"response.reasoning_text.delta","item_id":"rs_1","output_index":0,
        \\"content_index":0,"delta":" more"}
        ,
        \\{"type":"response.reasoning_text.delta","item_id":"rs_1","output_index":0,
        \\"content_index":1,"delta":"again"}
        ,
        \\{"type":"response.reasoning_text.done","item_id":"rs_1","output_index":0,
        \\"content_index":1,"text":"again"}
        ,
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"hi"}
        ,
    });
    try rig.frames.expect(
        \\reasoning_started
        \\reasoning:think
        \\reasoning: more
        \\reasoning_started
        \\reasoning:again
        \\text:hi
        \\
    );
}

test "a new reasoning item, a rising index, and answer text each start a new part" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,
        \\"delta":"**a**"}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"status":"completed","summary":[{"type":"summary_text","text":"**a**"}],
        \\"encrypted_content":"enc"}}
        ,
        \\{"type":"response.reasoning_summary_part.added","item_id":"rs_2","summary_index":0,
        \\"part":{"type":"summary_text","text":""}}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":0,
        \\"delta":"**b**"}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":1,
        \\"delta":"**c**"}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","delta":"d"}
        ,
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":""}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":1,
        \\"delta":""}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":1,
        \\"delta":"e"}
        ,
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_3","summary_index":1,
        \\"delta":"f"}
        ,
    });
    try rig.frames.expect(
        \\reasoning_started
        \\reasoning:**a**
        \\proof:openai-api-key:{"id":"rs_1","text":"**a**","encrypted_content":"enc","raw_text":""}
        \\reasoning_started
        \\reasoning:**b**
        \\reasoning_started
        \\reasoning:**c**
        \\reasoning:d
        \\reasoning:e
        \\text:answer
        \\reasoning_started
        \\reasoning:f
        \\
    );
}

test "empty reasoning without encryption keeps the answer of a plain account" {
    const payloads = [_][]const u8{
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],
        \\"encrypted_content":""}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":null,
        \\"content":null,"encrypted_content":null}}
        ,
    };
    for (payloads) |payload| {
        var rig: Rig = undefined;
        rig.init(.{
            .account = "openrouter-api-key",
            .endpoint = "e",
            .switches = .{ .plain_reasoning = true },
        });
        defer rig.deinit();
        try rig.frames.feed(&.{
            payload,
            \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1",
            \\"content":[{"type":"output_text","text":"answer"}]}}
            ,
            \\{"type":"response.completed","response":{"output":[{"type":"reasoning","id":"rs_1",
            \\"summary":[]},{"type":"message","id":"msg_1","content":[{"type":"output_text",
            \\"text":"answer"}]}],"usage":{"input_tokens":7,"output_tokens":3}}}
            ,
        });
        try rig.frames.expect(
            \\message:answer
            \\usage:7/3/0/0
            \\stopped:complete|
            \\
        );
    }
}

test "a plain account keeps the reasoning text of an item without encryption" {
    var rig: Rig = undefined;
    rig.init(.{
        .account = "deepseek-api-key",
        .endpoint = "e",
        .switches = .{ .plain_reasoning = true },
    });
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"summary":[{"type":"summary_text","text":"sum"}],"content":[{"type":"reasoning_text",
        \\"text":"raw"}]}}
    });
    try rig.frames.expect(
        \\proof:deepseek-api-key:{"id":"rs_1","text":"sum","encrypted_content":"","raw_text":"raw"}
        \\
    );
}

test "the terminal cost accepts numeric strings and preserves small charges" {
    const cases = [_]struct { value: []const u8, expected: []const u8 }{
        .{ .value = "0.000123", .expected = "|0.000123" },
        .{ .value = "\"0.000123\"", .expected = "|0.000123" },
        .{ .value = "\"1.23e-4\"", .expected = "|0.000123" },
        .{ .value = "0", .expected = "|0" },
        .{ .value = "1", .expected = "|1" },
        .{ .value = "1e9", .expected = "|1000000000" },
        .{ .value = "null", .expected = "" },
        .{ .value = "true", .expected = "" },
        .{ .value = "\"bad\"", .expected = "" },
        .{ .value = "\"nan\"", .expected = "" },
        .{ .value = "\"inf\"", .expected = "" },
        .{ .value = "-0.1", .expected = "" },
        .{ .value = "1e999", .expected = "" },
        .{ .value = "1e10", .expected = "" },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init(test_options);
        defer rig.deinit();
        const payload = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"type\":\"response.completed\",\"response\":{{\"usage\":{{\"cost\":{s}}}}}}}",
            .{case.value},
        );
        defer std.testing.allocator.free(payload);
        try rig.frames.feed(&.{payload});
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "usage:0/0/0/0{s}\nstopped:complete|\n",
            .{case.expected},
        );
        defer std.testing.allocator.free(expected);
        try rig.frames.expect(expected);
    }
}

test "an invalid completed reasoning item latches through the terminal usage" {
    const invalid = [_][]const u8{
        \\{"type":"response.output_item.done","item":{"type":"reasoning","summary":[],
        \\"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],
        \\"encrypted_content":42}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"status":"incomplete","summary":[],"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"summary":[{"type":"other","text":"hmm"}],"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],
        \\"content":[{"type":"other","text":"hmm"}]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],
        \\"content":[{"type":"reasoning_text"}]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"summary":[{"type":"summary_text","text":"hmm"}]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],
        \\"content":[{"type":"reasoning_text","text":"hmm"}]}}
        ,
    };
    for (invalid) |payload| {
        var rig: Rig = undefined;
        rig.init(test_options);
        defer rig.deinit();
        try rig.frames.feed(&.{
            payload,
            \\{"type":"response.completed","response":{"usage":{"input_tokens":7,
            \\"output_tokens":3}}}
            ,
        });
        try rig.frames.expect(
            \\usage:7/3/0/0
            \\failed:invalid_reply|-|
            \\
        );
    }
}

test "a refusal and an invalid function call latch until the terminal usage" {
    var refused: Rig = undefined;
    refused.init(test_options);
    defer refused.deinit();
    try refused.frames.feed(&.{
        \\{"type":"response.refusal.delta","delta":"cannot help"}
        ,
        \\{"type":"response.refusal.done","refusal":"cannot help"}
        ,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":9,
        \\"output_tokens":4}}}
        ,
    });
    try refused.frames.expect(
        \\usage:9/4/0/0
        \\failed:unsupported_reply|-|The reply holds content that Drinky cannot keep.
        \\
    );

    var calls: Rig = undefined;
    calls.init(test_options);
    defer calls.deinit();
    try calls.frames.feed(&.{
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1",
        \\"status":"incomplete","call_id":"call_1","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_2",
        \\"status":"completed","call_id":"call_1","name":"read"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_3",
        \\"status":"completed","call_id":"","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_4",
        \\"status":"completed","call_id":"call_1","arguments":"{}"}}
        ,
        \\{"type":"response.incomplete","response":{"status":"incomplete","usage":{"input_tokens":8,
        \\"output_tokens":2}}}
        ,
    });
    try calls.frames.expect(
        \\usage:8/2/0/0
        \\failed:invalid_reply|-|
        \\
    );
}

test "a streamed function call shows its name and arguments before its done item" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}
        ,
        \\{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try rig.frames.expect(
        \\tool_call_started:read
        \\tool_call_arguments:{}
        \\tool_call:call_1|read|{}
        \\stopped:complete|
        \\
    );
}

test "an id-less function call streams through its output index" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":4,"item":{"type":"function_call",
        \\"call_id":"call_1","name":"write"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":4,
        \\"delta":"{"}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try rig.frames.expect(
        \\tool_call_started:write
        \\tool_call_arguments:{
        \\stopped:complete|
        \\
    );
}

test "an argument fragment that names another item rejects the reply" {
    var named: Rig = undefined;
    named.init(test_options);
    defer named.deinit();
    try named.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{}"}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try named.frames.expect(
        \\tool_call_started:read
        \\failed:unsupported_reply|-|The stream named a block other than the open one.
        \\
    );

    var unnamed: Rig = undefined;
    unnamed.init(test_options);
    defer unnamed.deinit();
    try unnamed.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{}"}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try unnamed.frames.expect(
        \\failed:unsupported_reply|-|The stream named a block other than the open one.
        \\
    );
}

test "a fragment with no open call or an unnamed call paints nothing and keeps the reply" {
    var early: Rig = undefined;
    early.init(test_options);
    defer early.deinit();
    try early.frames.feed(&.{
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try early.frames.expect(
        \\tool_call:call_1|read|{}
        \\stopped:complete|
        \\
    );

    var unnamed: Rig = undefined;
    unnamed.init(test_options);
    defer unnamed.deinit();
    try unnamed.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try unnamed.frames.expect(
        \\tool_call:call_1|read|{}
        \\stopped:complete|
        \\
    );
}

test "a fragment after the done item of the open call keeps the reply" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,
        \\"delta":"{}"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.function_call_arguments.delta","item_id":"fc_2","output_index":1,
        \\"delta":"{\"path\":\"b\"}"}
        ,
        \\{"type":"response.output_item.done","output_index":1,"item":{"id":"fc_2",
        \\"type":"function_call","call_id":"call_2","name":"write","arguments":"{\"path\":\"b\"}"}}
        ,
        \\{"type":"response.completed","response":{"status":"completed"}}
        ,
    });
    try rig.frames.expect(
        \\tool_call_started:read
        \\tool_call_arguments:{}
        \\tool_call:call_1|read|{}
        \\tool_call:call_2|write|{"path":"b"}
        \\stopped:complete|
        \\
    );
}

test "a terminal event needs a response object, and an incomplete one carries its usage" {
    var malformed: Rig = undefined;
    malformed.init(test_options);
    defer malformed.deinit();
    try malformed.frames.feed(&.{
        \\{"type":"response.completed"}
    });
    try malformed.frames.expect("failed:invalid_reply|-|\n");

    var truncated: Rig = undefined;
    truncated.init(test_options);
    defer truncated.deinit();
    try truncated.frames.feed(&.{
        \\{"type":"response.incomplete","response":{"status":"incomplete",
        \\"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":50,
        \\"input_tokens_details":{"cached_tokens":10,"cache_write_tokens":5},
        \\"output_tokens":128000}}}
    });
    try truncated.frames.expect(
        \\usage:35/128000/10/5
        \\stopped:truncated|
        \\
    );
}

test "a streamed error frame fails with its reason and message" {
    const cases = [_]struct { payload: []const u8, expected: []const u8 }{
        .{
            .payload =
            \\{"type":"error","message":"rate limit"}
            ,
            .expected = "failed:invalid_request|-|rate limit\n",
        },
        .{
            .payload =
            \\{"type":"error","code":"server_error","message":"server failed"}
            ,
            .expected = "failed:overloaded|-|server failed\n",
        },
        .{
            .payload = "{\"type\":\"response.failed\",\"response\":{\"error\":" ++
                "{\"code\":\"rate_limit_exceeded\",\"message\":\"rate limited\"}}}",
            .expected = "failed:rate_limited|-|rate limited\n",
        },
        .{
            .payload = "{\"type\":\"response.failed\",\"response\":{\"error\":" ++
                "{\"code\":\"invalid_prompt\",\"message\":\"bad request\"}}}",
            .expected = "failed:invalid_request|-|bad request\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{"code":"insufficient_quota","message":"no funds"}}
            ,
            .expected = "failed:quota_exhausted|-|no funds\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{"code":"context_length_exceeded","message":"too long"}}
            ,
            .expected = "failed:context_overflow|-|too long\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{"type":"usage_limit_reached","plan_type":"pro",
            \\"resets_in_seconds":600}}
            ,
            .expected = "failed:quota_exhausted|600000|" ++
                "The Pro plan reached its usage limit. It resets in 10 minutes.\n",
        },
        .{
            .payload =
            \\{"type":"error"}
            ,
            .expected = "failed:invalid_request|-|\n",
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
        .status = .bad_request,
        .retry_after_ms = null,
        .body =
        \\{"error":{"type":"invalid_request_error","message":"bad request"}}
        ,
    }, "failed:invalid_request|-|400 Bad Request: bad request");
    try Rig.expectFailure(test_options, &.{
        .status = .unauthorized,
        .retry_after_ms = null,
        .body =
        \\{"message":"no account"}
        ,
    }, "failed:unauthorized|-|401 Unauthorized: no account");
    try Rig.expectFailure(test_options, &.{
        .status = .forbidden,
        .retry_after_ms = null,
        .body =
        \\{"code":"Client specified an invalid argument","error":"Incorrect API key provided"}
        ,
    }, "failed:invalid_request|-|403 Forbidden: Incorrect API key provided");
    try Rig.expectFailure(test_options, &.{
        .status = .internal_server_error,
        .retry_after_ms = null,
        .body =
        \\{"error":{"message":"cut off
        ,
    }, "failed:overloaded|-|500 Internal Server Error: {\"error\":{\"message\":\"cut off");
    try Rig.expectFailure(test_options, &.{
        .status = .bad_gateway,
        .retry_after_ms = null,
        .body = "<html>gateway</html>",
    }, "failed:overloaded|-|502 Bad Gateway: <html>gateway</html>");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = 7000,
        .body = "",
    }, "failed:rate_limited|7000|429 Too Many Requests");
    try Rig.expectFailure(test_options, &.{
        .status = .payment_required,
        .retry_after_ms = null,
        .body = "{}",
    }, "failed:quota_exhausted|-|402 Payment Required: {}");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = null,
        .body =
        \\{"error":{"code":"insufficient_quota","message":"no funds"}}
        ,
    }, "failed:quota_exhausted|-|429 Too Many Requests: no funds");
    try Rig.expectFailure(test_options, &.{
        .status = .bad_request,
        .retry_after_ms = null,
        .body =
        \\{"error":{"code":"context_length_exceeded","message":"too long"}}
        ,
    }, "failed:context_overflow|-|400 Bad Request: too long");
}

test "a failed head reports the upstream text of a routed error" {
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = null,
        .body = "{\"error\":{\"message\":\"Provider returned error\",\"code\":429," ++
            "\"metadata\":{\"raw\":\"upstream is rate-limited\",\"provider_name\":\"Makora\"}}}",
    }, "failed:rate_limited|-|429 Too Many Requests: upstream is rate-limited");
    try Rig.expectFailure(test_options, &.{
        .status = .bad_gateway,
        .retry_after_ms = null,
        .body =
        \\{"error":{"message":"Provider returned error","metadata":{"raw":""}}}
        ,
    }, "failed:overloaded|-|502 Bad Gateway: Provider returned error");
    try Rig.expectFailure(test_options, &.{
        .status = .bad_gateway,
        .retry_after_ms = null,
        .body =
        \\{"error":{"message":"Provider returned error","metadata":{"raw":{"code":429}}}}
        ,
    }, "failed:overloaded|-|502 Bad Gateway: Provider returned error");
    try Rig.expectFailure(test_options, &.{
        .status = @enumFromInt(529),
        .retry_after_ms = null,
        .body = "{\"error\":{\"message\":\"Provider returned error\",\"code\":529," ++
            "\"metadata\":{\"raw\":\"{\\\"type\\\":\\\"error\\\"," ++
            "\\\"error\\\":{\\\"type\\\":\\\"overloaded_error\\\"," ++
            "\\\"message\\\":\\\"Overloaded\\\"}}\",\"provider_name\":\"Anthropic\"}}}",
    }, "failed:overloaded|-|529: Overloaded");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = null,
        .body =
        \\{"error":{"message":"Provider returned error","metadata":{"raw":{"error":{"code":429,
        \\"message":"Resource exhausted"}}}}}
        ,
    }, "failed:rate_limited|-|429 Too Many Requests: Resource exhausted");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = null,
        .body =
        \\{"error":{"message":"Provider returned error",
        \\"metadata":{"raw":"{\"status\":\"RESOURCE_EXHAUSTED\"}"}}}
        ,
    }, "failed:rate_limited|-|429 Too Many Requests: {\"status\":\"RESOURCE_EXHAUSTED\"}");
}

test "a spent plan names the plan and the wait, and a head hint wins over the body" {
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = null,
        .body =
        \\{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached",
        \\"plan_type":"plus","resets_at":1787303122,"eligible_promo":null,
        \\"resets_in_seconds":321378}}
        ,
    }, "failed:quota_exhausted|321378000|429 Too Many Requests: " ++
        "The Plus plan reached its usage limit. It resets in 3 days 17 hours.");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = null,
        .body =
        \\{"error":{"type":"usage_limit_reached"}}
        ,
    }, "failed:quota_exhausted|-|429 Too Many Requests: " ++
        "The subscription reached its usage limit.");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = 7000,
        .body =
        \\{"error":{"type":"usage_limit_reached","resets_in_seconds":600}}
        ,
    }, "failed:quota_exhausted|7000|429 Too Many Requests: " ++
        "The subscription reached its usage limit. It resets in 10 minutes.");
}

test "the wait before a reset reads in at most two units" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("less than a minute", try resetText(allocator, 30));
    try std.testing.expectEqualStrings("1 minute", try resetText(allocator, 60));
    try std.testing.expectEqualStrings("59 minutes", try resetText(allocator, 3599));
    try std.testing.expectEqualStrings("1 hour", try resetText(allocator, 3600));
    try std.testing.expectEqualStrings("1 hour 1 minute", try resetText(allocator, 3660));
    try std.testing.expectEqualStrings("2 hours 30 minutes", try resetText(allocator, 9000));
    try std.testing.expectEqualStrings("1 day", try resetText(allocator, 86400));
    try std.testing.expectEqualStrings("1 day 1 hour", try resetText(allocator, 90000));
}

test "a malformed line and an unknown frame are filler, a structural frame is progress" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"type":"response.output_text.del
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode("not json at all"));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"type":"surprise.new.event"}
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"note":"no type here"}
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode("42"));
    try std.testing.expectEqual(Dialect.Decoded.progress, try rig.frames.decode(
        \\{"type":"response.in_progress","response":{}}
    ));
    try std.testing.expectEqual(Dialect.Decoded.done, try rig.frames.decode("[DONE]"));
    try rig.frames.expect("");
}

test "the head quota reads the Codex windows" {
    const both = [_]std.http.Header{
        .{ .name = "x-codex-primary-used-percent", .value = "11.5" },
        .{ .name = "x-codex-primary-window-minutes", .value = "300" },
        .{ .name = "x-codex-primary-reset-after-seconds", .value = "9000" },
        .{ .name = "x-codex-secondary-used-percent", .value = "74" },
        .{ .name = "x-codex-secondary-window-minutes", .value = "10080" },
        .{ .name = "x-codex-secondary-reset-after-seconds", .value = "580769" },
    };
    const quota_both = parseQuota(&both).?;
    try std.testing.expectEqual(@as(f64, 11.5), quota_both.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 300), quota_both.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 9000), quota_both.primary.?.reset_seconds);
    try std.testing.expectEqual(@as(f64, 74), quota_both.secondary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 10080), quota_both.secondary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 580_769), quota_both.secondary.?.reset_seconds);

    const weekly_primary = [_]std.http.Header{
        .{ .name = "x-codex-primary-used-percent", .value = "10" },
        .{ .name = "x-codex-primary-window-minutes", .value = "10080" },
        .{ .name = "x-codex-primary-reset-after-seconds", .value = "580769" },
        .{ .name = "x-codex-secondary-used-percent", .value = "0" },
        .{ .name = "x-codex-secondary-window-minutes", .value = "0" },
        .{ .name = "x-codex-secondary-reset-after-seconds", .value = "0" },
    };
    const slots = parseQuota(&weekly_primary).?;
    try std.testing.expectEqual(@as(?u32, 10080), slots.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 580_769), slots.primary.?.reset_seconds);
    try std.testing.expectEqual(@as(?u32, 0), slots.secondary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, null), slots.secondary.?.reset_seconds);

    const weekly = [_]std.http.Header{
        .{ .name = "X-Codex-Secondary-Used-Percent", .value = " 74 " },
        .{ .name = "x-codex-secondary-window-minutes", .value = "10080" },
    };
    const weekly_quota = parseQuota(&weekly).?;
    try std.testing.expect(weekly_quota.primary == null);
    try std.testing.expectEqual(@as(f64, 74), weekly_quota.secondary.?.used_percent);

    const partial = parseQuota(&.{.{ .name = "x-codex-primary-used-percent", .value = "5" }}).?;
    try std.testing.expectEqual(@as(f64, 5), partial.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, null), partial.primary.?.window_minutes);

    try std.testing.expect(parseQuota(&.{}) == null);
    try std.testing.expect(parseQuota(&.{
        .{ .name = "x-ratelimit-limit-requests", .value = "8300" },
        .{ .name = "x-ratelimit-remaining-tokens", .value = "53000000" },
    }) == null);
}

test "quota percentages and resets reject values that are no measurement" {
    try std.testing.expectEqual(@as(?f64, 0), parseQuotaPercent("0"));
    try std.testing.expectEqual(@as(?f64, 100), parseQuotaPercent("100"));
    try std.testing.expectEqual(@as(?f64, 100), parseQuotaPercent("100.1"));
    try std.testing.expect(parseQuotaPercent("nan") == null);
    try std.testing.expect(parseQuotaPercent("inf") == null);
    try std.testing.expect(parseQuotaPercent("-inf") == null);
    try std.testing.expect(parseQuotaPercent("-0.1") == null);
    try std.testing.expect(parseQuotaPercent("not-a-number") == null);

    try std.testing.expectEqual(@as(?u64, 580_769), parseResetSeconds("580769"));
    try std.testing.expectEqual(@as(?u64, 1), parseResetSeconds("1"));
    try std.testing.expect(parseResetSeconds("0") == null);
    try std.testing.expect(parseResetSeconds("") == null);
    try std.testing.expect(parseResetSeconds("-5") == null);
    try std.testing.expect(parseResetSeconds("soon") == null);
}

test "decoding frees its state at every allocation-failure point" {
    try Rig.checkDecodeAllocationFailures(test_options, &.{
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"summary":[{"type":"summary_text","text":"hmm"}],"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1",
        \\"type":"function_call","call_id":"call_1","name":"read"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1",
        \\"content":[{"type":"output_text","text":"one"}]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_2",
        \\"content":[{"type":"output_text","text":"two"}]}}
        ,
        \\{"type":"response.completed","response":{"model":"m","output":[{"type":"message",
        \\"id":"msg_1","content":[{"type":"output_text","text":"one"}]},{"type":"message",
        \\"id":"msg_2","content":[{"type":"output_text","text":"two"}]}]}}
        ,
    });
}
