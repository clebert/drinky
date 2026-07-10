//! Translates a neutral `llm.Request` into an Anthropic Messages API JSON body.
//! Holds no state and does no I/O — callers own the request and its backing
//! memory; `Client` sends the bytes this module produces.

const std = @import("std");

const llm = @import("../llm.zig");

/// Required first system block for subscription OAuth tokens.
pub const system_header = "You are Claude Code, Anthropic's official CLI for Claude.";

/// Serialize `request` into an owned JSON body; caller frees the result.
pub fn serialize(gpa: std.mem.Allocator, request: llm.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try string(writer, request.model);
    try writer.print(",\"max_tokens\":{d},\"stream\":true,\"system\":[", .{request.tokens_max});
    try writeSystemBlock(writer, system_header);
    try writer.writeAll(",");
    try writeSystemBlock(writer, request.system);
    try writer.writeAll("]");

    if (request.tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":");
            try string(writer, tool.name);
            try writer.writeAll(",\"description\":");
            try string(writer, tool.description);
            try writer.writeAll(",\"input_schema\":");
            try writer.writeAll(tool.schema_json);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    try writer.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, index| {
        if (index > 0) try writer.writeAll(",");
        try writeMessage(writer, message);
    }
    try writer.writeAll("]}");

    return out.toOwnedSlice();
}

fn writeSystemBlock(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try string(writer, text);
    try writer.writeAll("}");
}

fn writeMessage(writer: *std.Io.Writer, message: llm.Message) !void {
    try writer.writeAll("{\"role\":");
    try string(writer, @tagName(message.role));
    try writer.writeAll(",\"content\":[");
    for (message.blocks, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        try writeBlock(writer, block);
    }
    try writer.writeAll("]}");
}

fn writeBlock(writer: *std.Io.Writer, block: llm.Block) !void {
    switch (block) {
        .text => |text| {
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try string(writer, text);
            try writer.writeAll("}");
        },
        .tool_use => |use| {
            try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
            try string(writer, use.id);
            try writer.writeAll(",\"name\":");
            try string(writer, use.name);
            try writer.writeAll(",\"input\":");
            try writer.writeAll(if (use.input_json.len == 0) "{}" else use.input_json);
            try writer.writeAll("}");
        },
        .tool_result => |result| {
            try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try string(writer, result.tool_use_id);
            try writer.print(",\"is_error\":{},\"content\":", .{result.is_error});
            try string(writer, result.content);
            try writer.writeAll("}");
        },
    }
}

fn string(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

test serialize {
    const messages = [_]llm.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "hi \"there\"" }} },
    };
    const tools = [_]llm.Tool{
        .{ .name = "read", .description = "read a file", .schema_json = "{\"type\":\"object\"}" },
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
}
