//! Translates a neutral `llm.Request` into an Anthropic Messages API JSON body.
//! Holds no state and does no I/O — callers own the request and its backing
//! memory; `Transport` sends the bytes this module produces.

const std = @import("std");

const llm = @import("../llm.zig");

/// Required first system block for subscription OAuth tokens.
pub const system_header = "You are Claude Code, Anthropic's official CLI for Claude.";

/// Serialize `request` into an owned JSON body; caller frees the result.
pub fn serialize(gpa: std.mem.Allocator, request: llm.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try json.beginObject();
    try json.objectField("model");
    try json.write(request.model);
    try json.objectField("max_tokens");
    try json.write(request.tokens_max);
    try json.objectField("stream");
    try json.write(true);

    try json.objectField("system");
    try json.beginArray();
    try json.write(TextBlock{ .text = system_header });
    try json.write(TextBlock{ .text = request.system });
    try json.endArray();

    if (request.tools.len > 0) {
        try json.objectField("tools");
        try json.beginArray();
        for (request.tools) |tool| try writeTool(&json, tool);
        try json.endArray();
    }

    try json.objectField("messages");
    try json.beginArray();
    for (request.messages) |message| try writeMessage(&json, message);
    try json.endArray();
    try json.endObject();

    return out.toOwnedSlice();
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

const TextBlock = struct {
    type: []const u8 = "text",
    text: []const u8,
};

const ToolUseBlock = struct {
    type: []const u8 = "tool_use",
    id: []const u8,
    name: []const u8,
    input: RawJson,
};

const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    is_error: bool,
    content: []const u8,
};

fn writeTool(json: *std.json.Stringify, tool: llm.Tool) !void {
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
    try json.endObject();
}

fn writeMessage(json: *std.json.Stringify, message: llm.Message) !void {
    try json.beginObject();
    try json.objectField("role");
    try json.write(@tagName(message.role));
    try json.objectField("content");
    try json.beginArray();
    for (message.blocks) |block| try writeBlock(json, block);
    try json.endArray();
    try json.endObject();
}

fn writeBlock(json: *std.json.Stringify, block: llm.Block) !void {
    switch (block) {
        .text => |text| try json.write(TextBlock{ .text = text }),
        // The model emits tool input as JSON already, so embed it verbatim.
        .tool_use => |use| try json.write(ToolUseBlock{
            .id = use.id,
            .name = use.name,
            .input = .{ .bytes = if (use.input_json.len == 0) "{}" else use.input_json },
        }),
        .tool_result => |result| try json.write(ToolResultBlock{
            .tool_use_id = result.tool_use_id,
            .is_error = result.is_error,
            .content = result.content,
        }),
    }
}

test serialize {
    const messages = [_]llm.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "hi \"there\"" }} },
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
        .messages = &messages,
        .tools = &tools,
    });
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

test "tool_use input passes through raw, empty becomes an empty object" {
    const calls = [_]llm.Block{
        .{ .tool_use = .{ .id = "t1", .name = "read", .input_json = "{\"path\":\"a.zig\"}" } },
        .{ .tool_use = .{ .id = "t2", .name = "list", .input_json = "" } },
    };
    const results = [_]llm.Block{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok", .is_error = true } },
    };
    const messages = [_]llm.Message{
        .{ .role = .assistant, .blocks = &calls },
        .{ .role = .user, .blocks = &results },
    };
    const body = try serialize(std.testing.allocator, .{
        .model = "m",
        .tokens_max = 8,
        .system = "s",
        .messages = &messages,
        .tools = &.{},
    });
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("messages").?.array.items;
    const calls_content = items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("tool_use", calls_content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("a.zig", calls_content[0].object.get("input").?.object.get("path").?.string);
    try std.testing.expectEqual(@as(usize, 0), calls_content[1].object.get("input").?.object.count());

    const result = items[1].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_result", result.get("type").?.string);
    try std.testing.expectEqual(true, result.get("is_error").?.bool);
    try std.testing.expectEqualStrings("ok", result.get("content").?.string);
}
