const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");

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

    if (request.cache_key.len > 0) {
        try stringify.objectField("prompt_cache_key");
        try stringify.write(request.cache_key);
    }

    if (effortName(request)) |effort| {
        try stringify.objectField("reasoning");
        try stringify.write(Reasoning{ .effort = effort });
    }

    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        for (request.tools) |*tool| try writeTool(&stringify, tool);
        try stringify.endArray();
        try stringify.objectField("tool_choice");
        try stringify.write("auto");
        if (account.provider() != .openrouter) {
            try stringify.objectField("parallel_tool_calls");
            try stringify.write(true);
        }
    }

    try stringify.objectField("store");
    try stringify.write(false);
    if (!account.replaysPlainReasoning()) {
        try stringify.objectField("include");
        try stringify.beginArray();
        try stringify.write("reasoning.encrypted_content");
        try stringify.endArray();
    }

    try stringify.objectField("input");
    try stringify.beginArray();
    for (request.items) |*item| try writeItem(&stringify, gpa, item, account);
    try stringify.endArray();

    try stringify.objectField("stream");
    try stringify.write(true);
    if (account.provider() == .openrouter) {
        try stringify.objectField("provider");
        try stringify.write(.{ .require_parameters = true });
    }
    try stringify.endObject();

    return out.toOwnedSlice();
}

fn effortName(request: *const llm.Request) ?[]const u8 {
    return switch (request.reasoning) {
        .omitted => null,
        .named => |level| @tagName(level),
    };
}

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
        .reasoning => |*reasoning| switch (reasoning.replay) {
            inline .openai_plan,
            .openai_api_key,
            .xai_plan,
            .xai_api_key,
            .openrouter_api,
            .openrouter_api_key,
            .deepseek_api_key,
            .ds4,
            => |proof, tag| {
                if (tag == account and proof.replayable(account))
                    try writeReasoning(stringify, &proof);
            },
            .anthropic_plan,
            .anthropic_api_key,
            .anthropic_api,
            .google_cloud_key,
            => {},
        },
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

fn writeReasoning(
    stringify: *std.json.Stringify,
    replay: *const llm.Item.Reasoning.OpenAi,
) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("reasoning");
    try stringify.objectField("id");
    try stringify.write(replay.id);
    try stringify.objectField("summary");
    try stringify.beginArray();
    if (replay.text.len > 0) {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("summary_text");
        try stringify.objectField("text");
        try stringify.write(replay.text);
        try stringify.endObject();
    }
    try stringify.endArray();
    if (replay.encrypted_content.len != 0) {
        try stringify.objectField("encrypted_content");
        try stringify.write(replay.encrypted_content);
    } else if (replay.raw_text.len != 0) {
        try stringify.objectField("content");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("reasoning_text");
        try stringify.objectField("text");
        try stringify.write(replay.raw_text);
        try stringify.endObject();
        try stringify.endArray();
    }
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
    try stringify.objectField("arguments");
    try stringify.write(if (call.arguments_json.len == 0) "{}" else call.arguments_json);
    try stringify.endObject();
}

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
        .reasoning = .{ .named = .high },
    }, .openai_api_key);
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
    }, .openai_api_key);
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
    }, .openai_api_key);
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
    }, .openai_api_key);
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

test "a synthetic error result emits one function_call_output with one Error prefix" {
    const synthetic =
        "The tool stopped before Drinky recorded a result. " ++
        "Drinky does not know if the tool changed the system.";
    const items = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "call_1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_result = .{ .call_id = "call_1", .content = synthetic, .is_error = true } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-luna",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .openai_api_key);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expectEqualStrings("function_call_output", input[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[1].object.get("call_id").?.string);
    const output = input[1].object.get("output").?.string;
    const expected = "Error: " ++ synthetic;
    try std.testing.expectEqualStrings(expected, output);
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, output["Error: ".len..], "Error: "),
    );
}

test "reasoning replays only the active account's complete proof" {
    const items = [_]llm.Item{
        .{ .reasoning = .{
            .replay = .{ .openai_plan = .{
                .text = "weigh it",
                .id = "rs_1",
                .encrypted_content = "enc",
            } },
        } },
        .{ .reasoning = .{
            .replay = .{ .openai_api_key = .{
                .text = "foreign",
                .id = "rs_other",
                .encrypted_content = "other",
            } },
        } },
        .{ .reasoning = .{
            .replay = .{ .openai_plan = .{
                .text = "no blob",
                .id = "rs_2",
                .encrypted_content = "",
            } },
        } },
        .{ .message = .{ .role = .assistant, .text = "done" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "gpt-5.6-sol",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .openai_plan);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
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

    const grok_items = [_]llm.Item{
        .{ .reasoning = .{
            .replay = .{
                .xai_api_key = .{ .text = "", .id = "rs_x", .encrypted_content = "xenc" },
            },
        } },
    } ++ items;
    const grok_body = try serialize(std.testing.allocator, &.{
        .model = "grok-4.6",
        .tokens_max = 8,
        .system = "s",
        .items = &grok_items,
        .tools = &.{},
    }, .xai_api_key);
    defer std.testing.allocator.free(grok_body);
    const grok_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        grok_body,
        .{},
    );
    defer grok_parsed.deinit();
    const grok_input = grok_parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), grok_input.len);
    try std.testing.expectEqualStrings("rs_x", grok_input[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 0), grok_input[0].object.get("summary").?.array.items.len);
}

test "assistant text uses output_text, and no control omits reasoning" {
    const items = [_]llm.Item{
        .{ .message = .{ .role = .assistant, .text = "prior turn" } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "unlisted-model",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .openai_api_key);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("reasoning") == null);
    const content =
        root.get("input").?.array.items[0].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("output_text", content.get("type").?.string);
}

const golden_items = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .reasoning = .{ .replay = .{ .openai_api_key = .{
        .text = "think",
        .id = "rs_1",
        .encrypted_content = "enc1",
    } } } },
    .{ .tool_call = .{
        .call_id = "call_1",
        .name = "read",
        .arguments_json = "{\"path\":\"a.zig\"}",
    } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "call_1", .content = "contents", .is_error = false } },
    .{ .reasoning = .{ .replay = .{ .openai_api_key = .{
        .text = "",
        .id = "rs_2",
        .encrypted_content = "enc2",
    } } } },
    .{ .tool_call = .{
        .call_id = "call_2",
        .name = "write",
        .arguments_json = "{\"path\":\"b\"}",
    } },
    .{ .tool_result = .{ .call_id = "call_2", .content = "denied", .is_error = true } },
    .{ .reasoning = .{ .replay = .{ .openai_plan = .{
        .text = "foreign",
        .id = "rs_3",
        .encrypted_content = "enc3",
    } } } },
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
        .reasoning = .{ .named = .xhigh },
    }, .openai_api_key);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(golden, body);
}

test "an OpenRouter request requires parameters and replays its own proof" {
    const items = [_]llm.Item{
        .{ .reasoning = .{ .replay = .{ .openrouter_api_key = .{
            .text = "think",
            .id = "rs_or",
            .encrypted_content = "enc",
            .raw_text = "raw reasoning",
        } } } },
        .{ .reasoning = .{ .replay = .{ .openrouter_api = .{
            .text = "foreign summary",
            .id = "rs_foreign",
            .encrypted_content = "",
            .raw_text = "foreign reasoning",
        } } } },
        .{ .reasoning = .{ .replay = .{ .openrouter_api_key = .{
            .text = "",
            .id = "rs_plain",
            .encrypted_content = "",
            .raw_text = "plain reasoning",
        } } } },
    };
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "read a file", .parameters = &.{
            .{ .name = "path", .type = .string, .required = true, .description = "the path" },
        } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "openai/gpt-5.6-sol",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &tools,
    }, .openrouter_api_key);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
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

    inline for (.{
        llm.Account.openai_plan,
        llm.Account.openai_api_key,
        llm.Account.xai_plan,
        llm.Account.xai_api_key,
    }) |account| {
        const direct = try serialize(std.testing.allocator, &.{
            .model = "model",
            .tokens_max = 8,
            .system = "s",
            .items = &items,
            .tools = &tools,
        }, account);
        defer std.testing.allocator.free(direct);
        const direct_parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            direct,
            .{},
        );
        defer direct_parsed.deinit();
        const direct_root = direct_parsed.value.object;
        try std.testing.expect(direct_root.get("parallel_tool_calls").?.bool);
        try std.testing.expectEqualStrings(
            "reasoning.encrypted_content",
            direct_root.get("include").?.array.items[0].string,
        );
        try std.testing.expectEqual(@as(usize, 0), direct_root.get("input").?.array.items.len);
    }
}

test "a DwarfStar request replays an empty reasoning proof" {
    const items = [_]llm.Item{
        .{ .reasoning = .{ .replay = .{ .ds4 = .{
            .text = "",
            .id = "rs_local",
            .encrypted_content = "",
        } } } },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "deepseek-v4-pro",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }, .ds4);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("include") == null);
    const input = root.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try std.testing.expectEqualStrings("rs_local", input[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 0), input[0].object.get("summary").?.array.items.len);
    try std.testing.expect(input[0].object.get("encrypted_content") == null);
    try std.testing.expect(input[0].object.get("content") == null);
}

test "a DwarfStar request names parallel tools and asks for no encrypted content" {
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "read", .parameters = &.{} },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "deepseek-v4-pro",
        .tokens_max = 8,
        .system = "s",
        .items = &.{},
        .tools = &tools,
    }, .ds4);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("include") == null);
    try std.testing.expectEqual(false, root.get("store").?.bool);
    try std.testing.expect(root.get("parallel_tool_calls").?.bool);
    try std.testing.expectEqual(@as(usize, 1), root.get("tools").?.array.items.len);
}

test "a DeepSeek request replays plain reasoning and still names parallel tools" {
    const items = [_]llm.Item{
        .{ .reasoning = .{ .replay = .{ .deepseek_api_key = .{
            .text = "",
            .id = "rs_ds",
            .encrypted_content = "",
            .raw_text = "plain reasoning",
        } } } },
    };
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "read", .parameters = &.{} },
    };
    const body = try serialize(std.testing.allocator, &.{
        .model = "deepseek-v4-pro",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &tools,
    }, .deepseek_api_key);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("include") == null);
    try std.testing.expect(root.get("provider") == null);
    try std.testing.expect(root.get("parallel_tool_calls").?.bool);
    const input = root.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try std.testing.expect(input[0].object.get("encrypted_content") == null);
    const part = input[0].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("reasoning_text", part.get("type").?.string);
    try std.testing.expectEqualStrings("plain reasoning", part.get("text").?.string);
}
