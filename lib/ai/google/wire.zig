//! This module translates a neutral `llm.Request` into a Gemini
//! `generateContent` JSON body. It holds no state and does no I/O. Callers own
//! the request and its backing memory. `Transport` sends the bytes.
//!
//! A `reasoning` item of this account holds the `thoughtSignature` that Gemini
//! returned on one part, and the serializer puts it back on the next part it
//! writes for the model. No part travels for the item itself.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");

/// Serialize `request` into an owned JSON body. The caller frees the result.
pub fn serialize(gpa: std.mem.Allocator, request: *const llm.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try stringify.beginObject();
    try stringify.objectField("systemInstruction");
    try stringify.write(.{ .parts = [_]TextPart{.{ .text = request.system }} });

    try stringify.objectField("contents");
    try stringify.beginArray();
    try writeContents(&stringify, request.items);
    try stringify.endArray();

    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("functionDeclarations");
        try stringify.beginArray();
        for (request.tools) |*tool| try writeTool(&stringify, tool);
        try stringify.endArray();
        try stringify.endObject();
        try stringify.endArray();
    }

    // A model that never thinks rejects the field, so an omitted control sends
    // none. The Agent resolved a named level against the levels the model names,
    // so the name goes out as it stands.
    switch (request.reasoning) {
        .omitted => {},
        .named => |level| {
            try stringify.objectField("generationConfig");
            try stringify.write(.{ .thinkingConfig = ThinkingConfig{
                .thinkingLevel = @tagName(level),
            } });
        },
    }
    try stringify.endObject();

    return out.toOwnedSlice();
}

const TextPart = struct {
    text: []const u8,
    thoughtSignature: ?[]const u8 = null,
};

const FunctionCallPart = struct {
    functionCall: struct { name: []const u8, args: json.Raw },
    thoughtSignature: ?[]const u8 = null,
};

const FunctionResponsePart = struct {
    functionResponse: struct { name: []const u8, response: Response },

    /// The two keys the Gemini documentation names for a result and an error.
    const Response = union(enum) {
        output: []const u8,
        @"error": []const u8,
    };
};

const ThinkingConfig = struct {
    includeThoughts: bool = true,
    thinkingLevel: []const u8,
};

fn writeTool(stringify: *std.json.Stringify, tool: *const llm.Tool) !void {
    try stringify.beginObject();
    try stringify.objectField("name");
    try stringify.write(tool.name);
    try stringify.objectField("description");
    try stringify.write(tool.description);
    try stringify.objectField("parametersJsonSchema");
    try json.writeParametersSchema(stringify, tool.parameters);
    try stringify.endObject();
}

/// The entry an item belongs to. A tool call is model output, and a tool result
/// feeds back on the user side. A user entry never mixes function responses
/// with text, because the newer models refuse such an entry as no user turn.
const Entry = enum {
    model,
    user_text,
    user_response,

    fn of(item: llm.Item) Entry {
        return switch (item) {
            .message => |message| if (message.role == .user) .user_text else .model,
            .reasoning, .tool_call => .model,
            .tool_result => .user_response,
        };
    }
};

/// Write one `contents` entry per run of items that share an `Entry` and write
/// a part, in list order. A reasoning item writes no part, so it opens no entry.
/// Runs that such a skip leaves adjacent merge into one entry, because Gemini
/// rejects an entry with no part.
fn writeContents(stringify: *std.json.Stringify, items: []const llm.Item) !void {
    var open: ?Entry = null;
    var pending_signature: ?[]const u8 = null;
    for (items, 0..) |*item, index| {
        if (item.* == .reasoning) {
            // The signature of this account waits for the next part. A foreign
            // arm belongs to another account and writes nothing.
            switch (item.reasoning.replay) {
                .google_vertex => |signature| if (signature.signature.len != 0) {
                    pending_signature = signature.signature;
                },
                else => {},
            }
            continue;
        }
        const entry = Entry.of(item.*);
        if (open != entry) {
            if (open != null) try endContent(stringify);
            try stringify.beginObject();
            try stringify.objectField("role");
            try stringify.write(if (entry == .model) "model" else "user");
            try stringify.objectField("parts");
            try stringify.beginArray();
            open = entry;
        }
        switch (item.*) {
            .message => |message| try stringify.write(TextPart{
                .text = message.text,
                .thoughtSignature = if (entry == .model) pending_signature else null,
            }),
            .tool_call => |call| try stringify.write(FunctionCallPart{
                .functionCall = .{
                    .name = call.name,
                    .args = .{ .bytes = if (call.arguments_json.len == 0) "{}" else call.arguments_json },
                },
                .thoughtSignature = pending_signature,
            }),
            .tool_result => |result| try stringify.write(FunctionResponsePart{
                .functionResponse = .{
                    .name = try callName(items[0..index], result.call_id),
                    .response = if (result.is_error)
                        .{ .@"error" = result.content }
                    else
                        .{ .output = result.content },
                },
            }),
            .reasoning => unreachable,
        }
        // A model part carried the signature, and a user part drops it.
        pending_signature = null;
    }
    if (open != null) try endContent(stringify);
}

fn endContent(stringify: *std.json.Stringify) !void {
    try stringify.endArray();
    try stringify.endObject();
}

/// The name of the nearest preceding call with `call_id`. A `functionResponse`
/// names its function, not the call, so the pairing is positional and the name
/// comes from the call.
fn callName(prior: []const llm.Item, call_id: []const u8) ![]const u8 {
    var index = prior.len;
    while (index > 0) {
        index -= 1;
        switch (prior[index]) {
            .tool_call => |call| if (std.mem.eql(u8, call.call_id, call_id)) return call.name,
            else => {},
        }
    }
    return error.OrphanToolResult;
}

const golden_tools = [_]llm.Tool{
    .{ .name = "read", .description = "Read a file.", .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "The path." },
    } },
};

// Every byte-affecting path: merged user runs, a signature on a call and on a
// text part, a user part that drops a signature, a foreign arm that writes
// nothing, reasoning items that open no entry while the user runs around them
// merge, a user text behind a tool result that takes an entry of its own, the
// response name lookup, both response keys, and a tail signature that writes
// nothing.
const golden_items = [_]llm.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .message = .{ .role = .user, .text = "second" } },
    .{ .reasoning = .{ .replay = .{ .google_vertex = .{ .text = "weigh", .signature = "sig1" } } } },
    .{ .tool_call = .{ .call_id = "call_1", .name = "read", .arguments_json = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "call_1", .content = "contents", .is_error = false } },
    .{ .message = .{ .role = .user, .text = "steer" } },
    .{ .reasoning = .{ .replay = .{ .google_vertex = .{ .text = "", .signature = "sig2" } } } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
    .{ .message = .{ .role = .user, .text = "again" } },
    .{ .reasoning = .{ .replay = .{ .google_vertex = .{ .text = "", .signature = "dropped" } } } },
    .{ .message = .{ .role = .user, .text = "more" } },
    .{ .reasoning = .{ .replay = .{ .openai_api = .{
        .text = "foreign",
        .id = "rs_1",
        .encrypted_content = "enc",
    } } } },
    .{ .tool_call = .{ .call_id = "call_1", .name = "write", .arguments_json = "" } },
    .{ .tool_result = .{ .call_id = "call_1", .content = "done", .is_error = true } },
    .{ .reasoning = .{ .replay = .{ .google_vertex = .{ .text = "", .signature = "tail" } } } },
};

const golden_level =
    \\{"systemInstruction":{"parts":[{"text":"be terse"}]},"contents":[{"role":"user","parts":[{"text":"first"},{"text":"second"}]},{"role":"model","parts":[{"functionCall":{"name":"read","args":{"path":"a.zig"}},"thoughtSignature":"sig1"},{"text":"checking"}]},{"role":"user","parts":[{"functionResponse":{"name":"read","response":{"output":"contents"}}}]},{"role":"user","parts":[{"text":"steer"}]},{"role":"model","parts":[{"text":"all set","thoughtSignature":"sig2"}]},{"role":"user","parts":[{"text":"again"},{"text":"more"}]},{"role":"model","parts":[{"functionCall":{"name":"write","args":{}}}]},{"role":"user","parts":[{"functionResponse":{"name":"write","response":{"error":"done"}}}]}],"tools":[{"functionDeclarations":[{"name":"read","description":"Read a file.","parametersJsonSchema":{"type":"object","properties":{"path":{"type":"string","description":"The path."}},"required":["path"]}}]}],"generationConfig":{"thinkingConfig":{"includeThoughts":true,"thinkingLevel":"high"}}}
;

test "golden bytes place every signature and merge every run" {
    const body = try serialize(std.testing.allocator, &.{
        .model = "gemini-3-pro-preview",
        .tokens_max = 8192,
        .system = "be terse",
        .items = &golden_items,
        .tools = &golden_tools,
        .reasoning = .{ .named = .high },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(golden_level, body);
}

test "a named level sends the thoughts and its name, an omitted control sends no config" {
    const gpa = std.testing.allocator;
    const items = [_]llm.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    const named = try serialize(gpa, &.{
        .model = "gemini-3.5-flash",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
        .reasoning = .{ .named = .medium },
    });
    defer gpa.free(named);
    try std.testing.expectEqualStrings(
        \\{"systemInstruction":{"parts":[{"text":"s"}]},"contents":[{"role":"user","parts":[{"text":"hi"}]}],"generationConfig":{"thinkingConfig":{"includeThoughts":true,"thinkingLevel":"medium"}}}
    , named);

    const omitted = try serialize(gpa, &.{
        .model = "gemini-3.5-flash",
        .tokens_max = 8192,
        .system = "s",
        .items = &items,
        .tools = &.{},
    });
    defer gpa.free(omitted);
    try std.testing.expect(std.mem.indexOf(u8, omitted, "generationConfig") == null);
    try std.testing.expect(std.mem.indexOf(u8, omitted, "tools") == null);
}

test "a result without its call is an orphan" {
    const items = [_]llm.Item{
        .{ .tool_result = .{ .call_id = "call_9", .content = "x", .is_error = false } },
    };
    try std.testing.expectError(error.OrphanToolResult, serialize(std.testing.allocator, &.{
        .model = "m",
        .tokens_max = 8,
        .system = "s",
        .items = &items,
        .tools = &.{},
    }));
}
