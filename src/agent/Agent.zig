//! Drives one user turn to completion: append the message, stream the model's
//! reply, run any tools it calls, feed the results back, and repeat until the
//! model stops asking for tools. Owns the conversation history; presentation is
//! delegated to a `handler` with `onText`/`onToolStart`/`onToolResult`/`onError`.

const std = @import("std");

const Auth = @import("../anthropic/Auth.zig");
const Client = @import("../anthropic/Client.zig");
const message = @import("../anthropic/message.zig");
const tools = @import("tools.zig");

const Agent = @This();

const tokens_max = 8192;
const rounds_max = 50;

gpa: std.mem.Allocator,
io: std.Io,
auth: *Auth,
model: []const u8,
system: []const u8,
arena: std.heap.ArenaAllocator,
messages: std.ArrayList(message.Message),

pub fn init(gpa: std.mem.Allocator, io: std.Io, auth: *Auth, model: []const u8, system: []const u8) Agent {
    return .{
        .gpa = gpa,
        .io = io,
        .auth = auth,
        .model = model,
        .system = system,
        .arena = .init(gpa),
        .messages = .empty,
    };
}

pub fn deinit(self: *Agent) void {
    self.messages.deinit(self.gpa);
    self.arena.deinit();
}

/// Run one user turn, streaming output through `handler`.
pub fn run(self: *Agent, user_text: []const u8, handler: anytype) !void {
    const base = self.messages.items.len;
    errdefer self.messages.shrinkRetainingCapacity(base);
    try self.appendUser(user_text);
    var round: usize = 0;
    while (round < rounds_max) : (round += 1) {
        const token = try self.auth.accessToken();
        const body = try message.serialize(self.gpa, .{
            .model = self.model,
            .tokens_max = tokens_max,
            .system = self.system,
            .messages = self.messages.items,
            .tools = &tools.definitions,
        });
        defer self.gpa.free(body);

        var client: Client = .{ .gpa = self.gpa, .io = self.io };
        var stream: Client.Stream = undefined;
        try client.send(&stream, body, token);
        defer stream.deinit();

        if (stream.status != .ok) return self.reportAndReset(handler, stream.errorText(), base);
        const more = self.consume(&stream, handler) catch |err| switch (err) {
            error.ApiError => return self.reportAndReset(handler, stream.errorText(), base),
            else => return err,
        };
        if (!more) return;
    }
    return error.TooManyToolRounds;
}

/// Surface a failed turn to the handler and drop its messages so the history
/// stays a valid user/assistant alternation for the next turn.
fn reportAndReset(self: *Agent, handler: anytype, text: []const u8, base: usize) !void {
    self.messages.shrinkRetainingCapacity(base);
    try handler.onError(text);
}

fn appendUser(self: *Agent, text: []const u8) !void {
    const arena = self.arena.allocator();
    const blocks = try arena.alloc(message.Block, 1);
    blocks[0] = .{ .text = try arena.dupe(u8, text) };
    try self.messages.append(self.gpa, .{ .role = .user, .blocks = blocks });
}

/// Consume one streamed assistant message: record it, run its tools, and queue
/// the results. Returns true when tools ran and another round is needed.
fn consume(self: *Agent, stream: *Client.Stream, handler: anytype) !bool {
    const arena = self.arena.allocator();
    var blocks: std.ArrayList(message.Block) = .empty;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.gpa);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(self.gpa);
    var tool_id: []const u8 = "";
    var tool_name: []const u8 = "";
    var in_tool = false;

    while (try stream.next()) |event| switch (event) {
        .text => |delta| {
            try text.appendSlice(self.gpa, delta);
            try handler.onText(delta);
        },
        .tool_use => |use| {
            try flushText(arena, &blocks, &text);
            if (in_tool) try flushTool(arena, &blocks, tool_id, tool_name, &input);
            tool_id = try arena.dupe(u8, use.id);
            tool_name = try arena.dupe(u8, use.name);
            input.clearRetainingCapacity();
            in_tool = true;
        },
        .input_json => |chunk| try input.appendSlice(self.gpa, chunk),
        .stop => {},
    };
    try flushText(arena, &blocks, &text);
    if (in_tool) try flushTool(arena, &blocks, tool_id, tool_name, &input);

    const reply = try blocks.toOwnedSlice(arena);
    try self.messages.append(self.gpa, .{ .role = .assistant, .blocks = reply });

    var results: std.ArrayList(message.Block) = .empty;
    for (reply) |block| switch (block) {
        .tool_use => |use| {
            try handler.onToolStart(use.name, use.input_json);
            const result = try tools.run(self.gpa, self.io, use.name, use.input_json);
            defer self.gpa.free(result.content);
            try handler.onToolResult(use.name, result.content, result.is_error);
            try results.append(arena, .{ .tool_result = .{
                .tool_use_id = try arena.dupe(u8, use.id),
                .content = try arena.dupe(u8, result.content),
                .is_error = result.is_error,
            } });
        },
        else => {},
    };

    if (results.items.len == 0) return false;
    try self.messages.append(self.gpa, .{ .role = .user, .blocks = try results.toOwnedSlice(arena) });
    return true;
}

fn flushText(
    arena: std.mem.Allocator,
    blocks: *std.ArrayList(message.Block),
    text: *std.ArrayList(u8),
) !void {
    if (text.items.len == 0) return;
    try blocks.append(arena, .{ .text = try arena.dupe(u8, text.items) });
    text.clearRetainingCapacity();
}

fn flushTool(
    arena: std.mem.Allocator,
    blocks: *std.ArrayList(message.Block),
    id: []const u8,
    name: []const u8,
    input: *std.ArrayList(u8),
) !void {
    try blocks.append(arena, .{ .tool_use = .{
        .id = id,
        .name = name,
        .input_json = try arena.dupe(u8, input.items),
    } });
}
