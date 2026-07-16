//! Translates a neutral `llm.Request` into an OpenAI Responses API JSON body.
//! Shared by the API-key (`openai_api`) and ChatGPT-subscription
//! (`openai_subscription`) accounts — they differ only in transport base and
//! auth, never wire shape. Holds no state and does no I/O: callers own the
//! request and its backing memory; `Transport` sends the bytes this module
//! produces.

const std = @import("std");

const llm = @import("../llm.zig");
const models = @import("../models.zig");

/// Serialize `request` into an owned JSON body; caller frees the result.
/// `account` is the active openai account: it keys the per-model effort lookup
/// (through its vendor) and guards which stored reasoning items are replayed —
/// only blobs the exact same account produced, never a foreign one.
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
    try json.objectField("instructions");
    try json.write(request.system);

    // Reasoning-only models: steer depth with the named effort (resolved through
    // the per-model map, off floored on `none`) and ask for a readable summary.
    // A null result — an unknown model — omits the config entirely.
    if (effortName(request, account)) |effort| {
        try json.objectField("reasoning");
        try json.write(Reasoning{ .effort = effort });
    }

    // `request.tokens_max` is deliberately not sent as `max_output_tokens`: these
    // are reasoning models, so a client-imposed output cap risks truncating the
    // reasoning pass mid-turn. The model's own default budget governs instead.
    if (request.tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (request.tools) |tool| try writeTool(&json, tool);
        try json.endArray();
        try json.objectField("tool_choice");
        try json.write("auto");
        try json.objectField("parallel_tool_calls");
        try json.write(true);
    }

    // Stateless replay: never persist the turn server-side, and ask for the
    // reasoning tokens encrypted so a stored reasoning item round-trips next
    // turn (the model requires the reasoning that preceded a function call).
    try json.objectField("store");
    try json.write(false);
    try json.objectField("include");
    try json.beginArray();
    try json.write("reasoning.encrypted_content");
    try json.endArray();

    // Near pass-through: one input item per history item, in list order. OpenAI
    // needs no envelope merging — assistant reasoning, text, and tool calls each
    // stand as their own item — so unlike Anthropic there is nothing to group.
    try json.objectField("input");
    try json.beginArray();
    for (request.items) |item| try writeItem(&json, gpa, item, account);
    try json.endArray();

    try json.objectField("stream");
    try json.write(true);
    try json.endObject();

    return out.toOwnedSlice();
}

/// The OpenAI effort name for the request's level, resolved through the model's
/// effort map, or null to omit the reasoning config. An unknown model resolves
/// to null; every known openai model floors off on `none`, so it never does.
fn effortName(request: llm.Request, account: llm.Account) ?[]const u8 {
    const model = models.get(llm.provider(account), request.model) orelse return null;
    return model.effort.resolve(request.effort);
}

/// Adaptive reasoning control: the named effort steers depth, and a summary is
/// returned so the reasoning can be shown.
const Reasoning = struct {
    effort: []const u8,
    summary: []const u8 = "auto",
};

fn writeItem(json: *std.json.Stringify, gpa: std.mem.Allocator, item: llm.Item, account: llm.Account) !void {
    switch (item) {
        .message => |message| try writeMessage(json, message),
        // A reasoning item from any other account is dropped whole (its encrypted
        // content can't be replayed here); one from this account with no blob is
        // dropped too, since it can't be round-tripped without that token.
        .reasoning => |reasoning| if (reasoning.origin == account and reasoning.blob.len > 0)
            try writeReasoning(json, reasoning),
        .tool_call => |call| try writeToolCall(json, call),
        .tool_result => |result| try writeToolResult(json, gpa, result),
    }
}

fn writeMessage(json: *std.json.Stringify, message: llm.Item.Message) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("message");
    try json.objectField("role");
    try json.write(@tagName(message.role));
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write(if (message.role == .user) "input_text" else "output_text");
    try json.objectField("text");
    try json.write(message.text);
    try json.endObject();
    try json.endArray();
    try json.endObject();
}

/// A stored reasoning run: its server-assigned id, an optional summary, and the
/// verbatim encrypted token the model verifies to accept the calls that followed.
fn writeReasoning(json: *std.json.Stringify, reasoning: llm.Item.Reasoning) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("reasoning");
    try json.objectField("id");
    try json.write(reasoning.id);
    try json.objectField("summary");
    try json.beginArray();
    if (reasoning.text.len > 0) {
        try json.beginObject();
        try json.objectField("type");
        try json.write("summary_text");
        try json.objectField("text");
        try json.write(reasoning.text);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("encrypted_content");
    try json.write(reasoning.blob);
    try json.endObject();
}

fn writeToolCall(json: *std.json.Stringify, call: llm.Item.ToolCall) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("function_call");
    try json.objectField("call_id");
    try json.write(call.call_id);
    try json.objectField("name");
    try json.write(call.name);
    // Responses wants the arguments as a JSON string, not an embedded object, so
    // write the raw JSON escaped as a string value; empty means an empty object.
    try json.objectField("arguments");
    try json.write(if (call.arguments_json.len == 0) "{}" else call.arguments_json);
    try json.endObject();
}

/// A tool outcome fed back to the model. Responses has no error flag, so an
/// error is surfaced by prefixing the output text.
fn writeToolResult(json: *std.json.Stringify, gpa: std.mem.Allocator, result: llm.Item.ToolResult) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("function_call_output");
    try json.objectField("call_id");
    try json.write(result.call_id);
    try json.objectField("output");
    if (result.is_error) {
        const output = try std.fmt.allocPrint(gpa, "Error: {s}", .{result.content});
        defer gpa.free(output);
        try json.write(output);
    } else {
        try json.write(result.content);
    }
    try json.endObject();
}

fn writeTool(json: *std.json.Stringify, tool: llm.Tool) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("function");
    try json.objectField("name");
    try json.write(tool.name);
    try json.objectField("description");
    try json.write(tool.description);
    // Non-strict: the parameters are a plain JSON schema, so a tool need not mark
    // every property required or forbid extra keys the way strict mode demands.
    try json.objectField("strict");
    try json.write(false);
    try json.objectField("parameters");
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
    try json.endObject();
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
    try std.testing.expectEqualStrings("high", root.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", root.get("reasoning").?.object.get("summary").?.string);
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

test "tool_call arguments serialize as a JSON string, error output is prefixed" {
    const items = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "call_1", .name = "read", .arguments_json = "{\"path\":\"a.zig\"}" } },
        .{ .tool_call = .{ .call_id = "call_2", .name = "list", .arguments_json = "" } },
        .{ .tool_result = .{ .call_id = "call_1", .content = "boom", .is_error = true } },
        .{ .tool_result = .{ .call_id = "call_2", .content = "ok", .is_error = false } },
    };
    const body = try serialize(std.testing.allocator, .{
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

    // arguments is a JSON *string*, so it parses back as a string carrying JSON.
    try std.testing.expectEqualStrings("function_call", input[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", input[0].object.get("arguments").?.string);
    try std.testing.expectEqualStrings("{}", input[1].object.get("arguments").?.string);

    try std.testing.expectEqualStrings("function_call_output", input[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("Error: boom", input[2].object.get("output").?.string);
    try std.testing.expectEqualStrings("ok", input[3].object.get("output").?.string);
}

test "reasoning replays only the active account's blobs, dropping foreign and blobless" {
    const items = [_]llm.Item{
        .{ .reasoning = .{ .text = "weigh it", .blob = "enc", .id = "rs_1", .origin = .openai_subscription } },
        .{ .reasoning = .{ .text = "foreign", .blob = "sig", .id = "", .origin = .openai_api } },
        .{ .reasoning = .{ .text = "no blob", .blob = "", .id = "rs_2", .origin = .openai_subscription } },
        .{ .message = .{ .role = .assistant, .text = "done" } },
    };
    const body = try serialize(std.testing.allocator, .{
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
    // Only the first reasoning item (this account's origin, has a blob) and the
    // message survive; a different account's item and the blobless one are
    // dropped — replay is an exact account match, even within the same vendor.
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
    const body = try serialize(std.testing.allocator, .{
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
    const content = root.get("input").?.array.items[0].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("output_text", content.get("type").?.string);
}

// A representative multi-round conversation exercising every serializer path:
// interleaved reasoning/tool_call/text, a redacted-style blob-only reasoning
// item, an error tool result, an assistant turn, and a foreign reasoning item
// that must be dropped. Byte-identity guards the wire shape against drift the
// structural tests above would miss.
const golden_items = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .reasoning = .{ .text = "think", .blob = "enc1", .id = "rs_1", .origin = .openai_api } },
    .{ .tool_call = .{ .call_id = "call_1", .name = "read", .arguments_json = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "call_1", .content = "contents", .is_error = false } },
    .{ .reasoning = .{ .text = "", .blob = "enc2", .id = "rs_2", .origin = .openai_api } },
    .{ .tool_call = .{ .call_id = "call_2", .name = "write", .arguments_json = "{\"path\":\"b\"}" } },
    .{ .tool_result = .{ .call_id = "call_2", .content = "denied", .is_error = true } },
    .{ .reasoning = .{ .text = "foreign", .blob = "sig", .id = "", .origin = .openai_subscription } },
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
    const body = try serialize(std.testing.allocator, .{
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
