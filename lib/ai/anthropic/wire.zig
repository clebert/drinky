//! Translates a neutral `llm.Request` into an Anthropic Messages API JSON body.
//! Holds no state and does no I/O — callers own the request and its backing
//! memory; `Transport` sends the bytes this module produces.

const std = @import("std");

const llm = @import("../llm.zig");
const models = @import("../models.zig");

/// Required first system block on the subscription OAuth path (the Claude Code
/// identity). The API-key path omits it and sends only the user's own prompt.
pub const system_header = "You are Claude Code, Anthropic's official CLI for Claude.";

/// Serialize `request` into an owned JSON body; caller frees the result.
/// `account` is the active Anthropic account: the subscription path prepends the
/// Claude Code `system_header` and replays subscription-origin reasoning, while
/// the API-key path omits the header and replays only api-origin reasoning
/// (reasoning is kept only on an exact account match).
pub fn serialize(gpa: std.mem.Allocator, request: llm.Request, account: llm.Account) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try json.beginObject();
    try json.objectField("model");
    try json.write(request.model);
    try json.objectField("max_tokens");
    try json.write(request.tokens_max);
    try json.objectField("stream");
    try json.write(true);

    // Reasoning: let the model size its own budget (adaptive thinking) and steer
    // its depth with the named effort level, rather than picking a token budget
    // client-side. `summarized` keeps the reasoning readable for display. Every
    // level, none included, is resolved through the per-model effort map, so it
    // maps to what the model accepts; a null result omits the config entirely and
    // drops the stored thinking blocks from the history below.
    const reasoning = effortName(request);
    if (reasoning) |effort| {
        try json.objectField("thinking");
        try json.write(AdaptiveThinking{});
        try json.objectField("output_config");
        try json.write(OutputConfig{ .effort = effort });
    }

    // Prompt-cache breakpoints, model-independent: Anthropic caches the request
    // prefix (tools, then system, then messages, in that order) up to and
    // including each marked block, applying its own per-model minimum server
    // side. Mark the last system block and the last tool so the stable prefix is
    // cached, and the last block of the last message so the growing history is
    // read back next turn. Three of the four allowed breakpoints.
    try json.objectField("system");
    try json.beginArray();
    if (account == .anthropic_subscription) try json.write(TextBlock{ .text = system_header });
    try json.write(TextBlock{ .text = request.system, .cache_control = .{} });
    try json.endArray();

    if (request.tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (request.tools, 0..) |tool, index| {
            try writeTool(&json, tool, index == request.tools.len - 1);
        }
        try json.endArray();
    }

    // Rebuild alternating messages from the flat item list: open a message
    // envelope for each run of consecutive same-role items (a `tool_result` is a
    // `user` item) and emit one block per item in list order — never reordering
    // (reasoning already arrives at the head from the agent) and never
    // concatenating adjacent text (each stays its own block, preserving
    // `[tool_use, text]` interleaving and multi-text turns). An item that emits no
    // block (a reasoning item dropped because reasoning is disabled or its origin is a
    // different account) is skipped without opening an envelope, so an
    // assistant run that was reasoning-only never serializes to an empty
    // `content` array (which Anthropic rejects with a 400); two user runs left
    // adjacent by such a skip merge into one envelope. The last emitted block
    // carries the history cache breakpoint.
    try json.objectField("messages");
    try json.beginArray();
    const last_block = lastBlockIndex(request.items, reasoning != null, account);
    var open_role: ?llm.Role = null;
    for (request.items, 0..) |item, index| {
        if (!emitsBlock(item, reasoning != null, account)) continue;
        const role = itemRole(item);
        if (open_role == null or open_role.? != role) {
            if (open_role != null) try endMessage(&json);
            try json.beginObject();
            try json.objectField("role");
            try json.write(@tagName(role));
            try json.objectField("content");
            try json.beginArray();
            open_role = role;
        }
        try writeItem(&json, item, index == last_block);
    }
    if (open_role != null) try endMessage(&json);
    try json.endArray();
    try json.endObject();

    return out.toOwnedSlice();
}

/// The Anthropic effort name for the request's level, resolved through the
/// model's effort map, or null to omit the reasoning config. The none level, an
/// unknown model, and any level a model disables all resolve to null.
fn effortName(request: llm.Request) ?[]const u8 {
    const model = models.get(.anthropic, request.model) orelse return null;
    return model.effort.resolve(request.effort);
}

/// JSON bytes written through verbatim rather than re-encoded as a quoted
/// string, so an already-serialized value embeds as itself.
const RawJson = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: @This(), json: anytype) !void {
        try json.beginWriteRaw();
        try json.writer.writeAll(self.bytes);
        json.endWriteRaw();
    }
};

/// A prompt-cache breakpoint: the request prefix up to and including the block
/// carrying it is cached (5-minute ephemeral).
const CacheControl = struct { type: []const u8 = "ephemeral" };

/// Adaptive extended-thinking switch: the model sizes its own budget, and
/// `summarized` reasoning is returned so it can be shown.
const AdaptiveThinking = struct {
    type: []const u8 = "adaptive",
    display: []const u8 = "summarized",
};

/// The named effort level steering reasoning depth (and answer effort).
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
    input: RawJson,
    cache_control: ?CacheControl = null,
};

const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    is_error: bool,
    content: []const u8,
    cache_control: ?CacheControl = null,
};

fn writeTool(json: *std.json.Stringify, tool: llm.Tool, cache: bool) !void {
    try json.beginObject();
    try json.objectField("name");
    try json.write(tool.name);
    try json.objectField("description");
    try json.write(tool.description);
    try json.objectField("input_schema");
    try json.beginObject();
    try json.objectField("type");
    try json.write("object");
    try json.objectField("properties");
    try json.beginObject();
    for (tool.parameters) |parameter| {
        try json.objectField(parameter.name);
        try json.beginObject();
        try json.objectField("type");
        try json.write(@tagName(parameter.type));
        try json.objectField("description");
        try json.write(parameter.description);
        try json.endObject();
    }
    try json.endObject();
    try json.objectField("required");
    try json.beginArray();
    for (tool.parameters) |parameter| {
        if (parameter.required) try json.write(parameter.name);
    }
    try json.endArray();
    try json.endObject();
    if (cache) {
        try json.objectField("cache_control");
        try json.write(CacheControl{});
    }
    try json.endObject();
}

/// Whether an item serializes to a content block. Every item does except a
/// reasoning item that is dropped — reasoning disabled, or a blob from a different
/// account, neither of which this serializer can replay.
fn emitsBlock(item: llm.Item, emit_thinking: bool, account: llm.Account) bool {
    return switch (item) {
        .reasoning => |reasoning| emit_thinking and reasoning.origin == account,
        else => true,
    };
}

/// Index of the last item that emits a block, or null when none do — the block
/// that carries the history cache breakpoint.
fn lastBlockIndex(items: []const llm.Item, emit_thinking: bool, account: llm.Account) ?usize {
    var last: ?usize = null;
    for (items, 0..) |item, index| {
        if (emitsBlock(item, emit_thinking, account)) last = index;
    }
    return last;
}

/// The Anthropic message role an item belongs to: reasoning and tool calls are
/// assistant output; a tool result is fed back as a user item.
fn itemRole(item: llm.Item) llm.Role {
    return switch (item) {
        .message => |message| message.role,
        .reasoning, .tool_call => .assistant,
        .tool_result => .user,
    };
}

fn endMessage(json: *std.json.Stringify) !void {
    try json.endArray();
    try json.endObject();
}

fn writeItem(json: *std.json.Stringify, item: llm.Item, cache: bool) !void {
    const control: ?CacheControl = if (cache) .{} else null;
    switch (item) {
        .message => |message| try json.write(TextBlock{ .text = message.text, .cache_control = control }),
        // `emitsBlock` already dropped any reasoning this account cannot replay, so
        // reaching here means the blob is ours. Reasoning sits at the head of an
        // assistant message, never as the cached last block, so it carries no
        // cache breakpoint.
        .reasoning => |reasoning| try writeThinking(json, reasoning),
        // The model emits tool arguments as JSON already, so embed them verbatim.
        .tool_call => |call| try json.write(ToolUseBlock{
            .id = call.call_id,
            .name = call.name,
            .input = .{ .bytes = if (call.arguments_json.len == 0) "{}" else call.arguments_json },
            .cache_control = control,
        }),
        .tool_result => |result| try json.write(ToolResultBlock{
            .tool_use_id = result.call_id,
            .is_error = result.is_error,
            .content = result.content,
            .cache_control = control,
        }),
    }
}

/// Serialize a stored reasoning item: a normal block with its verbatim
/// signature, or a redacted block carrying its encrypted payload.
fn writeThinking(json: *std.json.Stringify, reasoning: llm.Item.Reasoning) !void {
    if (reasoning.redacted)
        try json.write(RedactedThinkingBlock{ .data = reasoning.blob })
    else
        try json.write(ThinkingBlock{ .thinking = reasoning.text, .signature = reasoning.blob });
}

test serialize {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hi \"there\"" } },
    };
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "read a file", .parameters = &.{
            .{ .name = "path", .type = .string, .required = true, .description = "the file path" },
        } },
    };
    const body = try serialize(std.testing.allocator, .{
        .model = "claude-sonnet-4-6",
        .tokens_max = 1024,
        .system = "be terse",
        .items = &items,
        .tools = &tools,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-4-6", root.get("model").?.string);
    try std.testing.expectEqual(true, root.get("stream").?.bool);
    try std.testing.expectEqual(@as(usize, 2), root.get("system").?.array.items.len);
    try std.testing.expectEqualStrings(
        system_header,
        root.get("system").?.array.items[0].object.get("text").?.string,
    );
    try std.testing.expectEqualStrings(
        "hi \"there\"",
        root.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string,
    );
    const input_schema = root.get("tools").?.array.items[0].object.get("input_schema").?.object;
    try std.testing.expectEqualStrings("object", input_schema.get("type").?.string);
    try std.testing.expectEqualStrings(
        "string",
        input_schema.get("properties").?.object.get("path").?.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings("path", input_schema.get("required").?.array.items[0].string);
}

test "tool_call arguments pass through raw, empty becomes an empty object" {
    const items = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "t1", .name = "read", .arguments_json = "{\"path\":\"a.zig\"}" } },
        .{ .tool_call = .{ .call_id = "t2", .name = "list", .arguments_json = "" } },
        .{ .tool_result = .{ .call_id = "t1", .content = "ok", .is_error = true } },
    };
    const body = try serialize(std.testing.allocator, .{
        .model = "m",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    const calls_content = messages[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("tool_use", calls_content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("a.zig", calls_content[0].object.get("input").?.object.get("path").?.string);
    try std.testing.expectEqual(@as(usize, 0), calls_content[1].object.get("input").?.object.count());

    const result = messages[1].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_result", result.get("type").?.string);
    try std.testing.expectEqual(true, result.get("is_error").?.bool);
    try std.testing.expectEqualStrings("ok", result.get("content").?.string);
}

// The model string is arbitrary here: cache breakpoints are placed the same way
// for every model, so this proves caching does not depend on the model.
test "cache_control marks the system prompt, last tool, and last message block" {
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "d", .parameters = &.{} },
        .{ .name = "grep", .description = "d", .parameters = &.{} },
    };
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hello" } },
        .{ .message = .{ .role = .assistant, .text = "a" } },
        .{ .message = .{ .role = .assistant, .text = "b" } },
    };
    const body = try serialize(std.testing.allocator, .{
        .model = "any-model-x",
        .tokens_max = 8,
        .system = "sys",
        .items = &items,
        .tools = &tools,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const system = root.get("system").?.array.items;
    try std.testing.expect(system[0].object.get("cache_control") == null);
    const marker = system[1].object.get("cache_control").?.object;
    try std.testing.expectEqualStrings("ephemeral", marker.get("type").?.string);

    const tool_items = root.get("tools").?.array.items;
    try std.testing.expect(tool_items[0].object.get("cache_control") == null);
    try std.testing.expect(tool_items[1].object.get("cache_control") != null);

    const message_items = root.get("messages").?.array.items;
    const first_blocks = message_items[0].object.get("content").?.array.items;
    try std.testing.expect(first_blocks[0].object.get("cache_control") == null);
    const last_blocks = message_items[1].object.get("content").?.array.items;
    try std.testing.expect(last_blocks[0].object.get("cache_control") == null);
    try std.testing.expect(last_blocks[1].object.get("cache_control") != null);
}

test "effort is dropped for a model with no table entry" {
    // A model absent from the table has no effort map, so the requested level is
    // dropped rather than emitted blindly — proof the level is resolved through
    // the per-model table, not from @tagName.
    const items = [_]llm.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    const body = try serialize(std.testing.allocator, .{
        .model = "unlisted-model",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .effort = .max,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("thinking") == null);
    try std.testing.expect(parsed.value.object.get("output_config") == null);
}

test "an effort level a model lacks folds to one it accepts" {
    // Sonnet 4.6 has no xhigh; its per-model map folds an xhigh request onto
    // high, so the default effort works without the user knowing.
    const items = [_]llm.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    const body = try serialize(std.testing.allocator, .{
        .model = "claude-sonnet-4-6",
        .tokens_max = 128_000,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .effort = .xhigh,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "high",
        parsed.value.object.get("output_config").?.object.get("effort").?.string,
    );
}

test "no thinking or output_config when effort is none" {
    const items = [_]llm.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    const body = try serialize(std.testing.allocator, .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("thinking") == null);
    try std.testing.expect(parsed.value.object.get("output_config") == null);
    try std.testing.expectEqual(@as(i64, 8192), parsed.value.object.get("max_tokens").?.integer);
}

// A representative multi-round conversation exercising every serializer path
// that affects the bytes: a steering-folded two-text-block user turn (two
// consecutive user items sharing one envelope), an assistant run with a normal
// and a redacted reasoning block at its head, an interleaved [tool_call, text]
// run, tool results with both is_error values, and several role transitions.
const golden_items = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .message = .{ .role = .user, .text = "second" } },
    .{ .reasoning = .{ .text = "weigh it", .blob = "sig", .origin = .anthropic_subscription } },
    .{ .reasoning = .{ .text = "", .blob = "secret", .redacted = true, .origin = .anthropic_subscription } },
    .{ .tool_call = .{ .call_id = "t1", .name = "read", .arguments_json = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "t1", .content = "contents", .is_error = false } },
    .{ .reasoning = .{ .text = "more", .blob = "sig2", .origin = .anthropic_subscription } },
    .{ .tool_call = .{ .call_id = "t2", .name = "write", .arguments_json = "{\"path\":\"b\"}" } },
    .{ .tool_result = .{ .call_id = "t2", .content = "done", .is_error = true } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden_on =
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"xhigh"},"system":[{"type":"text","text":"You are Claude Code, Anthropic's official CLI for Claude."},{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it","signature":"sig"},{"type":"redacted_thinking","data":"secret"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"checking"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"contents"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"more","signature":"sig2"},{"type":"tool_use","id":"t2","name":"write","input":{"path":"b"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"done"}]},{"role":"assistant","content":[{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
;

const golden_none =
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"system":[{"type":"text","text":"You are Claude Code, Anthropic's official CLI for Claude."},{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"checking"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"contents"}]},{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"write","input":{"path":"b"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"done"}]},{"role":"assistant","content":[{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
;

// Byte-identity with the pre-reshape output guards the pure-refactor claim and
// Anthropic's server-side prompt cache: a changed prefix invalidates the cache
// across a deploy. Serializing with reasoning on, then at effort none, proves
// the none level drops the thinking blocks and the reasoning config with no
// other byte change. Both use the subscription account, whose reasoning origin
// matches so the blocks replay.
test "serialized bytes match the pre-reshape wire output" {
    const on = try serialize(std.testing.allocator, .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items,
        .tools = &.{},
        .effort = .xhigh,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(on);
    try std.testing.expectEqualStrings(golden_on, on);

    const none = try serialize(std.testing.allocator, .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items,
        .tools = &.{},
        .effort = .none,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings(golden_none, none);
}

// The API-key account drops the Claude Code `system_header` (sending only the
// user's own system prompt) and replays reasoning tagged with its own account,
// with every other block byte-identical to the subscription path. This fixture
// covers a user turn, an api-origin thinking block replayed at the assistant
// head, an interleaved tool call, and the cached final text block.
const golden_items_api = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .reasoning = .{ .text = "weigh it", .blob = "sig", .origin = .anthropic_api } },
    .{ .tool_call = .{ .call_id = "t1", .name = "read", .arguments_json = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden_api =
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"xhigh"},"system":[{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"first"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it","signature":"sig"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
;

test "the api-key account omits the system header and keeps every other block" {
    const body = try serialize(std.testing.allocator, .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items_api,
        .tools = &.{},
        .effort = .xhigh,
    }, .anthropic_api);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(golden_api, body);
}

test "a reasoning-only run dropped by an account switch emits no empty envelope" {
    // A reasoning-only assistant run (reasoning produced by the subscription
    // account, then the turn stopped) sits between two user turns. Serialized
    // under the api-key account, exact-account replay drops that reasoning, so the
    // assistant run would be empty — it must be skipped, not written as
    // `"content":[]` (a 400), and the two user turns then share one envelope.
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
        .{ .reasoning = .{ .text = "weigh it", .blob = "sig", .origin = .anthropic_subscription } },
        .{ .message = .{ .role = .user, .text = "again" } },
    };
    const body = try serialize(std.testing.allocator, .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .effort = .xhigh,
    }, .anthropic_api);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    const content = messages[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("hi", content[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("again", content[1].object.get("text").?.string);
    // The last emitted block carries the history cache breakpoint.
    try std.testing.expect(content[1].object.get("cache_control") != null);
}

test "reasoning is dropped when its origin account differs, even within the vendor" {
    // A subscription-origin reasoning item serialized under the api-key account:
    // replay is an exact account match, so it drops though both are Anthropic.
    const items = [_]llm.Item{
        .{ .reasoning = .{ .text = "weigh it", .blob = "sig", .origin = .anthropic_subscription } },
        .{ .message = .{ .role = .assistant, .text = "answer" } },
    };
    const body = try serialize(std.testing.allocator, .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .effort = .xhigh,
    }, .anthropic_api);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("answer", content[0].object.get("text").?.string);
}
