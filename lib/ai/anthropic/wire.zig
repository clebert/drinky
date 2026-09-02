//! This module translates a neutral `llm.Request` into an Anthropic Messages
//! API JSON body. It holds no state and does no I/O. Callers own the request
//! and its backing memory. `Transport` sends the bytes this module produces.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");

/// The exact leading identity the Claude Code compatibility path expects. Both
/// the subscription and the Console account send it, so the Console key reaches
/// every model. The plain API-key path omits it and sends only the user's own
/// prompt.
const system_header = "You are Claude Code, Anthropic's official CLI for Claude.";

/// Whether `account` leads its system prompt with the Claude Code identity
/// header. The subscription and Console accounts send it, so their keys reach
/// every model. A plain API key omits it. A new account must decide here.
fn sendsSystemHeader(account: llm.Account) bool {
    return switch (account) {
        .anthropic_subscription, .anthropic_console => true,
        .anthropic_api, .openai_subscription, .openai_api, .google_vertex => false,
    };
}

/// Serialize `request` into an owned JSON body. The caller frees the result.
/// `account` decides whether to prepend the Claude Code `system_header` (the
/// subscription and Console accounts) and which stored reasoning replays (see
/// `emitsBlock`).
pub fn serialize(gpa: std.mem.Allocator, request: *const llm.Request, account: llm.Account) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try stringify.beginObject();
    try stringify.objectField("model");
    try stringify.write(request.model);
    try stringify.objectField("max_tokens");
    try stringify.write(request.tokens_max);
    try stringify.objectField("stream");
    try stringify.write(true);

    // The request carries no control, or adaptive thinking with a named level.
    // The Agent resolved it against the model.
    const emit_thinking = request.reasoning.replaysReasoning(.anthropic);
    switch (request.reasoning) {
        .omitted => {},
        .named => |level| {
            try stringify.objectField("thinking");
            try stringify.write(AdaptiveThinking{});
            try stringify.objectField("output_config");
            try stringify.write(OutputConfig{ .effort = @tagName(level) });
        },
    }

    // Prompt-cache breakpoints, model-independent: Anthropic caches the prefix
    // (tools, then system, then messages) up to each marked block and applies
    // its per-model minimum server side. Mark the last system block, the last
    // tool, and the two history blocks of `Breakpoints` — all four allowed.
    try stringify.objectField("system");
    try stringify.beginArray();
    if (sendsSystemHeader(account))
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

    // The loop writes one envelope per run of consecutive same-role items and
    // one block per item in list order. It never reorders or concatenates
    // adjacent text. An item that emits no block (dropped reasoning) must not
    // open an envelope: a reasoning-only assistant run then serializes as empty
    // `content`, which Anthropic rejects with a 400. User runs left adjacent by
    // such a skip merge.
    try stringify.objectField("messages");
    try stringify.beginArray();
    const breakpoints = historyBreakpoints(request.items, emit_thinking, account);
    var open_role: ?llm.Role = null;
    for (request.items, 0..) |*item, index| {
        if (!emitsBlock(item.*, emit_thinking, account)) continue;
        const role = itemRole(item.*);
        if (open_role == null or open_role.? != role) {
            if (open_role != null) try endMessage(&stringify);
            try stringify.beginObject();
            try stringify.objectField("role");
            try stringify.write(@tagName(role));
            try stringify.objectField("content");
            try stringify.beginArray();
            open_role = role;
        }
        try writeItem(&stringify, item, breakpoints.carries(index));
    }
    if (open_role != null) try endMessage(&stringify);
    try stringify.endArray();
    try stringify.endObject();

    return out.toOwnedSlice();
}

/// A prompt-cache breakpoint: Anthropic caches the request prefix up to and
/// including the block that carries it (5-minute ephemeral).
const CacheControl = struct { type: []const u8 = "ephemeral" };

/// The adaptive extended-thinking switch: the model sizes its own budget, and
/// the API returns `summarized` reasoning for display.
const AdaptiveThinking = struct {
    type: []const u8 = "adaptive",
    display: []const u8 = "summarized",
};

/// The named effort level that steers reasoning depth (and answer effort).
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

fn writeTool(stringify: *std.json.Stringify, tool: *const llm.Tool, cache: bool) !void {
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

/// Whether an item serializes to a content block. Reasoning drops when the
/// request names no thinking control, when it belongs to another account, or
/// when it carries a different provider's replay proof.
fn emitsBlock(item: llm.Item, emit_thinking: bool, account: llm.Account) bool {
    return switch (item) {
        .reasoning => |reasoning| if (!emit_thinking)
            false
        else switch (reasoning.replay) {
            inline .anthropic_subscription,
            .anthropic_api,
            .anthropic_console,
            => |proof, tag| proof: {
                if (tag != account) break :proof false;
                break :proof switch (proof) {
                    .signature => |signature| signature.signature.len != 0,
                    .redacted => |data| data.len != 0,
                };
            },
            .openai_subscription, .openai_api, .google_vertex => false,
        },
        else => true,
    };
}

/// The item indices that carry the two history cache breakpoints, or null
/// where no item emits a block.
const Breakpoints = struct {
    /// The last emitted block. It writes the entry for this request.
    current: ?usize = null,
    /// The last block of the most recent closed user envelope. It carried the
    /// breakpoint of the previous request. The server then reads that entry even
    /// when the new turn adds more blocks than its automatic prefix check scans
    /// back (about 20).
    previous: ?usize = null,

    fn carries(self: *const Breakpoints, index: usize) bool {
        return index == self.current or index == self.previous;
    }
};

fn historyBreakpoints(
    items: []const llm.Item,
    emit_thinking: bool,
    account: llm.Account,
) Breakpoints {
    var breakpoints: Breakpoints = .{};
    var open_role: ?llm.Role = null;
    for (items, 0..) |item, index| {
        if (!emitsBlock(item, emit_thinking, account)) continue;
        const role = itemRole(item);
        if (open_role == .user and role == .assistant) breakpoints.previous = breakpoints.current;
        open_role = role;
        breakpoints.current = index;
    }
    return breakpoints;
}

/// The Anthropic message role an item belongs to: reasoning and tool calls are
/// assistant output. A tool result feeds back as a user item.
fn itemRole(item: llm.Item) llm.Role {
    return switch (item) {
        .message => |message| message.role,
        .reasoning, .tool_call => .assistant,
        .tool_result => .user,
    };
}

fn endMessage(stringify: *std.json.Stringify) !void {
    try stringify.endArray();
    try stringify.endObject();
}

fn writeItem(stringify: *std.json.Stringify, item: *const llm.Item, cache: bool) !void {
    const control: ?CacheControl = if (cache) .{} else null;
    switch (item.*) {
        .message => |message| try stringify.write(TextBlock{
            .text = message.text,
            .cache_control = control,
        }),
        // Reasoning sits at the head of an assistant message, never as the
        // cached last block, so it carries no cache breakpoint.
        .reasoning => |*reasoning| try writeThinking(stringify, reasoning),
        // The model emits tool arguments as JSON already, so embed them verbatim.
        .tool_call => |call| try stringify.write(ToolUseBlock{
            .id = call.call_id,
            .name = call.name,
            .input = .{ .bytes = if (call.arguments_json.len == 0) "{}" else call.arguments_json },
            .cache_control = control,
        }),
        .tool_result => |result| try stringify.write(ToolResultBlock{
            .tool_use_id = result.call_id,
            .is_error = result.is_error,
            .content = result.content,
            .cache_control = control,
        }),
    }
}

/// Serialize a stored Anthropic replay proof as normal or redacted thinking.
fn writeThinking(stringify: *std.json.Stringify, reasoning: *const llm.Item.Reasoning) !void {
    switch (reasoning.replay) {
        inline .anthropic_subscription,
        .anthropic_api,
        .anthropic_console,
        => |proof| switch (proof) {
            .signature => |signature| try stringify.write(ThinkingBlock{
                .thinking = signature.text,
                .signature = signature.signature,
            }),
            .redacted => |data| try stringify.write(RedactedThinkingBlock{ .data = data }),
        },
        .openai_subscription, .openai_api, .google_vertex => unreachable,
    }
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
    const body = try serialize(std.testing.allocator, &.{
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
        root.get("messages").?.array.items[0].object
            .get("content").?.array.items[0].object.get("text").?.string,
    );
    const input_schema = root.get("tools").?.array.items[0].object.get("input_schema").?.object;
    try std.testing.expectEqualStrings("object", input_schema.get("type").?.string);
    try std.testing.expectEqualStrings(
        "string",
        input_schema.get("properties").?.object.get("path").?.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        "path",
        input_schema.get("required").?.array.items[0].string,
    );
}

test "tool_call arguments pass through raw, empty becomes an empty object" {
    const items = [_]llm.Item{
        .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{\"path\":\"a.zig\"}",
        } },
        .{ .tool_call = .{ .call_id = "t2", .name = "list", .arguments_json = "" } },
        .{ .tool_result = .{ .call_id = "t1", .content = "ok", .is_error = true } },
    };
    const body = try serialize(std.testing.allocator, &.{
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
    try std.testing.expectEqualStrings(
        "a.zig",
        calls_content[0].object.get("input").?.object.get("path").?.string,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        calls_content[1].object.get("input").?.object.count(),
    );

    const result = messages[1].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_result", result.get("type").?.string);
    try std.testing.expectEqual(true, result.get("is_error").?.bool);
    try std.testing.expectEqualStrings("ok", result.get("content").?.string);
}

test "synthetic error results group in one user envelope before steering text" {
    const synthetic =
        "The tool stopped before Drinky recorded a result. " ++
        "Drinky does not know if the tool changed the system.";
    const items = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "t1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "t2", .name = "read", .arguments_json = "{}" } },
        .{ .tool_result = .{ .call_id = "t1", .content = synthetic, .is_error = true } },
        .{ .tool_result = .{ .call_id = "t2", .content = synthetic, .is_error = true } },
        .{ .message = .{ .role = .user, .text = "steer" } },
    };
    const body = try serialize(std.testing.allocator, &.{
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
    // One assistant envelope for the calls, then one user envelope that groups
    // both immediate error results ahead of the steering text.
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    const content = messages[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), content.len);
    try std.testing.expectEqualStrings("tool_result", content[0].object.get("type").?.string);
    try std.testing.expectEqual(true, content[0].object.get("is_error").?.bool);
    try std.testing.expectEqualStrings("t1", content[0].object.get("tool_use_id").?.string);
    // Stored verbatim with no `Error:` prefix.
    try std.testing.expectEqualStrings(synthetic, content[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("tool_result", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("t2", content[1].object.get("tool_use_id").?.string);
    // The steering text follows the results in the same user envelope.
    try std.testing.expectEqualStrings("text", content[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("steer", content[2].object.get("text").?.string);
}

// The model string is arbitrary: the serializer places breakpoints the same way for every model.
test "cache_control marks the system prompt, last tool, previous user block, and last block" {
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "d", .parameters = &.{} },
        .{ .name = "grep", .description = "d", .parameters = &.{} },
    };
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hello" } },
        .{ .message = .{ .role = .assistant, .text = "a" } },
        .{ .message = .{ .role = .assistant, .text = "b" } },
    };
    const body = try serialize(std.testing.allocator, &.{
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
    try std.testing.expect(first_blocks[0].object.get("cache_control") != null);
    const last_blocks = message_items[1].object.get("content").?.array.items;
    try std.testing.expect(last_blocks[0].object.get("cache_control") == null);
    try std.testing.expect(last_blocks[1].object.get("cache_control") != null);
}

// The previous request ended at the steering text, so its breakpoint sat there.
// The breakpoint on that block lets the server read the entry when the new turn
// adds more blocks than its prefix check scans back. The tool result in the same
// envelope carries none.
test "cache_control also marks the last block of the previous user envelope" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hello" } },
        .{ .tool_call = .{ .call_id = "t1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_result = .{ .call_id = "t1", .content = "c", .is_error = false } },
        .{ .message = .{ .role = .user, .text = "steer" } },
        .{ .message = .{ .role = .assistant, .text = "a" } },
        .{ .message = .{ .role = .user, .text = "next" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "any-model-x",
        .tokens_max = 8,
        .system = "sys",
        .items = &items,
        .tools = &.{},
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const envelopes = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), envelopes.len);
    // One flag per block in envelope order: hello, t1, result, steer, a, next.
    const marked = [_]bool{ false, false, false, true, false, true };
    var block_index: usize = 0;
    for (envelopes) |envelope| {
        for (envelope.object.get("content").?.array.items) |block| {
            try std.testing.expect(block_index < marked.len);
            const actual = block.object.get("cache_control") != null;
            try std.testing.expectEqual(marked[block_index], actual);
            block_index += 1;
        }
    }
    try std.testing.expectEqual(marked.len, block_index);
}

test "every reasoning control renders its own block" {
    const gpa = std.testing.allocator;
    const items = [_]llm.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    const request: llm.Request = .{
        .model = "any-model",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
    };

    // A request that names no control writes no thinking block at all, so the
    // model keeps its own default.
    {
        const body = try serialize(gpa, &request, .anthropic_subscription);
        defer gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("thinking") == null);
        try std.testing.expect(parsed.value.object.get("output_config") == null);
    }

    // A named level renders adaptive thinking and states the level verbatim.
    {
        var named = request;
        named.reasoning = .{ .named = .xhigh };
        const body = try serialize(gpa, &named, .anthropic_subscription);
        defer gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings(
            "adaptive",
            root.get("thinking").?.object.get("type").?.string,
        );
        try std.testing.expectEqualStrings(
            "xhigh",
            root.get("output_config").?.object.get("effort").?.string,
        );
    }
}

test "an omitted control writes no thinking and no output_config" {
    const items = [_]llm.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    const body = try serialize(std.testing.allocator, &.{
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

// Anthropic rejects a thinking block in a request that names no thinking control,
// so an omitted control drops the stored replay.
test "an omitted control drops the replay" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
        .{ .reasoning = .{ .replay = .{ .anthropic_subscription = .{ .signature = .{
            .text = "think",
            .signature = "sig",
        } } } } },
        .{ .message = .{ .role = .assistant, .text = "answer" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-5",
        .tokens_max = 128_000,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .reasoning = .omitted,
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("thinking") == null);
    try std.testing.expect(root.get("output_config") == null);
    const assistant = root.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), assistant.len);
    try std.testing.expectEqualStrings("text", assistant[0].object.get("type").?.string);
}

test "a named control writes adaptive thinking and keeps the replay" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
        .{ .reasoning = .{ .replay = .{ .anthropic_subscription = .{ .signature = .{
            .text = "think",
            .signature = "sig",
        } } } } },
        .{ .message = .{ .role = .assistant, .text = "answer" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "claude-fable-5",
        .tokens_max = 128_000,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .reasoning = .{ .named = .low },
    }, .anthropic_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        "adaptive",
        root.get("thinking").?.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        "low",
        root.get("output_config").?.object.get("effort").?.string,
    );
    const assistant = root.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), assistant.len);
    try std.testing.expectEqualStrings("thinking", assistant[0].object.get("type").?.string);
}

// A multi-round conversation that exercises every byte-affecting serializer
// path: a two-text-block user turn, normal and redacted reasoning at an
// assistant head, [tool_call, text] interleaving, both is_error values, role
// transitions.
const golden_items = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .message = .{ .role = .user, .text = "second" } },
    .{ .reasoning = .{ .replay = .{ .anthropic_subscription = .{ .signature = .{
        .text = "weigh it",
        .signature = "sig",
    } } } } },
    .{ .reasoning = .{
        .replay = .{ .anthropic_subscription = .{ .redacted = "secret" } },
    } },
    .{ .tool_call = .{
        .call_id = "t1",
        .name = "read",
        .arguments_json = "{\"path\":\"a.zig\"}",
    } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "t1", .content = "contents", .is_error = false } },
    .{ .reasoning = .{ .replay = .{ .anthropic_subscription = .{ .signature = .{
        .text = "more",
        .signature = "sig2",
    } } } } },
    .{ .tool_call = .{ .call_id = "t2", .name = "write", .arguments_json = "{\"path\":\"b\"}" } },
    .{ .tool_result = .{ .call_id = "t2", .content = "done", .is_error = true } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden_on =
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"xhigh"},"system":[{"type":"text","text":"You are Claude Code, Anthropic's official CLI for Claude."},{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it","signature":"sig"},{"type":"redacted_thinking","data":"secret"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"checking"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"contents"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"more","signature":"sig2"},{"type":"tool_use","id":"t2","name":"write","input":{"path":"b"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"done","cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
;

const golden_none =
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"system":[{"type":"text","text":"You are Claude Code, Anthropic's official CLI for Claude."},{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"checking"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"contents"}]},{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"write","input":{"path":"b"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"done","cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
;

// Golden bytes keep the serialized prefix stable for Anthropic's server-side
// prompt cache: a changed prefix invalidates the cache across a deploy.
// Reasoning on vs. effort none proves the none level drops the thinking
// blocks and the reasoning config with no other byte change.
test "golden bytes keep the serialized prefix stable" {
    const on = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items,
        .tools = &.{},
        .reasoning = .{ .named = .xhigh },
    }, .anthropic_subscription);
    defer std.testing.allocator.free(on);
    try std.testing.expectEqualStrings(golden_on, on);

    const none = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items,
        .tools = &.{},
    }, .anthropic_subscription);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings(golden_none, none);
}

// The API-key account drops the `system_header` and replays its own account's
// reasoning, with every other block byte-identical to the subscription path.
const golden_items_api = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .reasoning = .{ .replay = .{ .anthropic_api = .{ .signature = .{
        .text = "weigh it",
        .signature = "sig",
    } } } } },
    .{ .tool_call = .{
        .call_id = "t1",
        .name = "read",
        .arguments_json = "{\"path\":\"a.zig\"}",
    } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden_api =
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"xhigh"},"system":[{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"first","cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it","signature":"sig"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
;

test "the api-key account omits the system header and keeps every other block" {
    const body = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items_api,
        .tools = &.{},
        .reasoning = .{ .named = .xhigh },
    }, .anthropic_api);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(golden_api, body);
}

test "the console account prepends the Claude Code header and replays its own reasoning" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "first" } },
        .{ .reasoning = .{ .replay = .{ .anthropic_console = .{ .signature = .{
            .text = "weigh it",
            .signature = "sig",
        } } } } },
        .{ .message = .{ .role = .assistant, .text = "all set" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &items,
        .tools = &.{},
        .reasoning = .{ .named = .xhigh },
    }, .anthropic_console);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const system = root.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), system.len);
    try std.testing.expectEqualStrings(system_header, system[0].object.get("text").?.string);
    const assistant = root.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("thinking", assistant[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("weigh it", assistant[0].object.get("thinking").?.string);
}

test "a reasoning-only run dropped by an account switch emits no empty envelope" {
    // Exact-account replay drops the reasoning-only assistant run between two
    // user turns. The serializer must skip it, not write `"content":[]`, and
    // the user turns then share one envelope.
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
        .{ .reasoning = .{ .replay = .{ .anthropic_subscription = .{ .signature = .{
            .text = "weigh it",
            .signature = "sig",
        } } } } },
        .{ .message = .{ .role = .user, .text = "again" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .reasoning = .{ .named = .xhigh },
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
    try std.testing.expect(content[1].object.get("cache_control") != null);
}

test "reasoning is dropped when its replay account differs within the vendor" {
    // Replay is an exact account match, so it drops though both are Anthropic.
    const items = [_]llm.Item{
        .{ .reasoning = .{ .replay = .{ .anthropic_subscription = .{ .signature = .{
            .text = "weigh it",
            .signature = "sig",
        } } } } },
        .{ .message = .{ .role = .assistant, .text = "answer" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .reasoning = .{ .named = .xhigh },
    }, .anthropic_api);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const content =
        parsed.value.object.get("messages").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("answer", content[0].object.get("text").?.string);
}
