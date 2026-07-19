//! Translates a neutral `llm.Request` into an OpenAI Responses API JSON body.
//! Shared by the API-key and ChatGPT-subscription accounts, which differ only
//! in transport base and auth, never wire shape. Holds no state and does no
//! I/O; `Transport` sends the bytes this module produces.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const models = @import("../models.zig");

/// Serialize `request` into an owned JSON body; caller frees the result.
/// `account` keys the per-model effort lookup and guards which stored
/// reasoning items are replayed (see `writeItem`).
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
    try stringify.objectField("instructions");
    try stringify.write(request.system);

    // OpenAI prompt caching is automatic and server-side (a >=1024-token prefix
    // caches on its own). The key only steers routing — combined with the
    // prompt-prefix hash so a session's growing requests land on the same
    // cache — and the gpt-5.6 family needs it set for reliable matching.
    if (request.cache_key.len > 0) {
        try stringify.objectField("prompt_cache_key");
        try stringify.write(request.cache_key);
    }

    // Steer reasoning depth with the named effort; a null resolution (an
    // unknown model) omits the config.
    if (effortName(request, account)) |effort| {
        try stringify.objectField("reasoning");
        try stringify.write(Reasoning{ .effort = effort });
    }

    // `request.tokens_max` is deliberately not sent as `max_output_tokens`: these
    // are reasoning models, so a client-imposed output cap risks truncating the
    // reasoning pass mid-turn. The model's own default budget governs instead.
    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        for (request.tools) |*tool| try writeTool(&stringify, tool);
        try stringify.endArray();
        try stringify.objectField("tool_choice");
        try stringify.write("auto");
        try stringify.objectField("parallel_tool_calls");
        try stringify.write(true);
    }

    // Stateless replay: never persist the turn server-side, and ask for the
    // reasoning tokens encrypted so a stored reasoning item round-trips next
    // turn (the model requires the reasoning that preceded a function call).
    try stringify.objectField("store");
    try stringify.write(false);
    try stringify.objectField("include");
    try stringify.beginArray();
    try stringify.write("reasoning.encrypted_content");
    try stringify.endArray();

    // Near pass-through: one input item per history item, in list order —
    // unlike Anthropic, OpenAI needs no envelope merging.
    try stringify.objectField("input");
    try stringify.beginArray();
    for (request.items) |*item| try writeItem(&stringify, gpa, item, account);
    try stringify.endArray();

    try stringify.objectField("stream");
    try stringify.write(true);
    try stringify.endObject();

    return out.toOwnedSlice();
}

/// The OpenAI effort name for the request's level, resolved through the model's
/// effort map, or null to omit the reasoning config. An unknown model resolves
/// to null; every known openai model floors the none level on `none`, so it
/// never does.
fn effortName(request: *const llm.Request, account: llm.Account) ?[]const u8 {
    const model = models.get(account.provider(), request.model) orelse return null;
    return model.effort.resolve(request.effort);
}

/// Adaptive reasoning control: the named effort steers depth, and a summary is
/// returned so the reasoning can be shown.
const Reasoning = struct {
    effort: []const u8,
    summary: []const u8 = "auto",
};

fn writeItem(
    stringify: *std.json.Stringify,
    gpa: std.mem.Allocator,
    item: *const llm.Item,
    account: llm.Account,
) !void {
    switch (item.*) {
        .message => |*message| try writeMessage(stringify, message),
        // A reasoning item from any other account is dropped whole (its encrypted
        // content can't be replayed here); one from this account with no blob is
        // dropped too, since it can't be round-tripped without that token.
        .reasoning => |*reasoning| if (reasoning.origin == account and reasoning.blob.len > 0)
            try writeReasoning(stringify, reasoning),
        .tool_call => |*call| try writeToolCall(stringify, call),
        .tool_result => |*result| try writeToolResult(stringify, gpa, result),
    }
}

fn writeMessage(stringify: *std.json.Stringify, message: *const llm.Item.Message) !void {
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

/// A stored reasoning run: its server-assigned id, an optional summary, and the
/// verbatim encrypted token the model verifies to accept the calls that followed.
fn writeReasoning(stringify: *std.json.Stringify, reasoning: *const llm.Item.Reasoning) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("reasoning");
    try stringify.objectField("id");
    try stringify.write(reasoning.id);
    try stringify.objectField("summary");
    try stringify.beginArray();
    if (reasoning.text.len > 0) {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("summary_text");
        try stringify.objectField("text");
        try stringify.write(reasoning.text);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.objectField("encrypted_content");
    try stringify.write(reasoning.blob);
    try stringify.endObject();
}

fn writeToolCall(stringify: *std.json.Stringify, call: *const llm.Item.ToolCall) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("function_call");
    try stringify.objectField("call_id");
    try stringify.write(call.call_id);
    try stringify.objectField("name");
    try stringify.write(call.name);
    // Responses wants the arguments as a JSON string, not an embedded object, so
    // write the raw JSON escaped as a string value; empty means an empty object.
    try stringify.objectField("arguments");
    try stringify.write(if (call.arguments_json.len == 0) "{}" else call.arguments_json);
    try stringify.endObject();
}

/// A tool outcome fed back to the model. Responses has no error flag, so an
/// error is surfaced by prefixing the output text.
fn writeToolResult(
    stringify: *std.json.Stringify,
    gpa: std.mem.Allocator,
    result: *const llm.Item.ToolResult,
) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("function_call_output");
    try stringify.objectField("call_id");
    try stringify.write(result.call_id);
    try stringify.objectField("output");
    if (result.is_error) {
        const output = try std.fmt.allocPrint(gpa, "Error: {s}", .{result.content});
        defer gpa.free(output);
        try stringify.write(output);
    } else {
        try stringify.write(result.content);
    }
    try stringify.endObject();
}

fn writeTool(stringify: *std.json.Stringify, tool: *const llm.Tool) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("function");
    try stringify.objectField("name");
    try stringify.write(tool.name);
    try stringify.objectField("description");
    try stringify.write(tool.description);
    // Non-strict: the parameters are a plain JSON schema, so a tool need not mark
    // every property required or forbid extra keys the way strict mode demands.
    try stringify.objectField("strict");
    try stringify.write(false);
    try stringify.objectField("parameters");
    try json.writeParametersSchema(stringify, tool.parameters);
    try stringify.endObject();
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
        .model = "gpt-5.6-sol",
        .tokens_max = 1024,
        .system = "be terse",
        .items = &items,
        .tools = &tools,
        .effort = .high,
    }, .openai_api);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-5.6-sol", root.get("model").?.string);
    try std.testing.expectEqualStrings("be terse", root.get("instructions").?.string);
    try std.testing.expectEqual(false, root.get("store").?.bool);
    try std.testing.expectEqual(true, root.get("stream").?.bool);
    try std.testing.expectEqualStrings(
        "high",
        root.get("reasoning").?.object.get("effort").?.string,
    );
    try std.testing.expectEqualStrings(
        "auto",
        root.get("reasoning").?.object.get("summary").?.string,
    );
    try std.testing.expectEqualStrings(
        "reasoning.encrypted_content",
        root.get("include").?.array.items[0].string,
    );

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
}

test "prompt_cache_key is sent when set and omitted when empty" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
    };
    const with_key = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-sol",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .cache_key = "session-abc",
    }, .openai_api);
    defer std.testing.allocator.free(with_key);
    {
        const parsed =
            try std.json.parseFromSlice(std.json.Value, std.testing.allocator, with_key, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            "session-abc",
            parsed.value.object.get("prompt_cache_key").?.string,
        );
    }

    const no_key = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-sol",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .openai_api);
    defer std.testing.allocator.free(no_key);
    {
        const parsed =
            try std.json.parseFromSlice(std.json.Value, std.testing.allocator, no_key, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("prompt_cache_key") == null);
    }
}

test "tool_call arguments serialize as a JSON string, error output is prefixed" {
    const items = [_]llm.Item{
        .{ .tool_call = .{
            .call_id = "call_1",
            .name = "read",
            .arguments_json = "{\"path\":\"a.zig\"}",
        } },
        .{ .tool_call = .{ .call_id = "call_2", .name = "list", .arguments_json = "" } },
        .{ .tool_result = .{ .call_id = "call_1", .content = "boom", .is_error = true } },
        .{ .tool_result = .{ .call_id = "call_2", .content = "ok", .is_error = false } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-luna",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .openai_api);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
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
}

test "reasoning replays only the active account's blobs, dropping foreign and blobless" {
    const items = [_]llm.Item{
        .{ .reasoning = .{
            .text = "weigh it",
            .blob = "enc",
            .id = "rs_1",
            .origin = .openai_subscription,
        } },
        .{ .reasoning = .{ .text = "foreign", .blob = "sig", .id = "", .origin = .openai_api } },
        .{ .reasoning = .{
            .text = "no blob",
            .blob = "",
            .id = "rs_2",
            .origin = .openai_subscription,
        } },
        .{ .message = .{ .role = .assistant, .text = "done" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-sol",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .openai_subscription);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    // Only this account's blob-carrying reasoning item and the message survive.
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

test "assistant text uses output_text, unknown model omits reasoning" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .assistant, .text = "prior turn" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "unlisted-model",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .effort = .high,
    }, .openai_api);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("reasoning") == null);
    const content =
        root.get("input").?.array.items[0].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("output_text", content.get("type").?.string);
}

// A multi-round conversation exercising every serializer path. Byte-identity
// guards the wire shape against drift the structural tests above would miss.
const golden_items = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .reasoning = .{ .text = "think", .blob = "enc1", .id = "rs_1", .origin = .openai_api } },
    .{ .tool_call = .{
        .call_id = "call_1",
        .name = "read",
        .arguments_json = "{\"path\":\"a.zig\"}",
    } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "call_1", .content = "contents", .is_error = false } },
    .{ .reasoning = .{ .text = "", .blob = "enc2", .id = "rs_2", .origin = .openai_api } },
    .{ .tool_call = .{
        .call_id = "call_2",
        .name = "write",
        .arguments_json = "{\"path\":\"b\"}",
    } },
    .{ .tool_result = .{ .call_id = "call_2", .content = "denied", .is_error = true } },
    .{ .reasoning = .{
        .text = "foreign",
        .blob = "sig",
        .id = "",
        .origin = .openai_subscription,
    } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden =
    \\{"model":"gpt-5.6-sol","instructions":"be terse","reasoning":{"effort":"xhigh","summary":"auto"},"tools":[{"type":"function","name":"read","description":"read a file","strict":false,"parameters":{"type":"object","properties":{"path":{"type":"string","description":"the path"}},"required":["path"]}}],"tool_choice":"auto","parallel_tool_calls":true,"store":false,"include":["reasoning.encrypted_content"],"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"first"}]},{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"think"}],"encrypted_content":"enc1"},{"type":"function_call","call_id":"call_1","name":"read","arguments":"{\"path\":\"a.zig\"}"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"checking"}]},{"type":"function_call_output","call_id":"call_1","output":"contents"},{"type":"reasoning","id":"rs_2","summary":[],"encrypted_content":"enc2"},{"type":"function_call","call_id":"call_2","name":"write","arguments":"{\"path\":\"b\"}"},{"type":"function_call_output","call_id":"call_2","output":"Error: denied"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"all set"}]}],"stream":true}
;

test "serialized bytes match the expected Responses wire output" {
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "read a file", .parameters = &.{
            .{ .name = "path", .type = .string, .required = true, .description = "the path" },
        } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-sol",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items,
        .tools = &tools,
        .effort = .xhigh,
    }, .openai_api);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(golden, body);
}
