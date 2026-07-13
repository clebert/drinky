//! Drives one user turn to completion: append the message, stream the model's
//! reply, run any tools it calls, feed the results back, and repeat until the
//! model stops asking for tools. Owns the conversation history and talks to the
//! model through a neutral `provider.Client`; presentation is delegated to a
//! `handler` with `onText`/`onToolStart`/`onToolResult`/`onUsage`/`onError`.

const std = @import("std");

const llm = @import("llm.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const tool = @import("tool/root.zig");

const Agent = @This();

const rounds_max = 50;

gpa: std.mem.Allocator,
io: std.Io,
client: provider.Client,
model: models.Model,
system: []const u8,
arena: std.heap.ArenaAllocator,
messages: std.ArrayList(llm.Message),
stats: Stats,

/// Cumulative dollar cost and cache savings over the session, plus the most
/// recent message's usage for the cache-hit and context-window gauges.
pub const Stats = struct {
    cost: f64 = 0,
    saved: f64 = 0,
    last: llm.Usage = .{},
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: provider.Client,
    options: struct { model: models.Model, system: []const u8 },
) Agent {
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .model = options.model,
        .system = options.system,
        .arena = .init(gpa),
        .messages = .empty,
        .stats = .{},
    };
}

pub fn deinit(self: *Agent) void {
    self.messages.deinit(self.gpa);
    self.arena.deinit();
}

/// Switch the active model; takes effect on the next turn. History is untouched,
/// so the new model reads the same conversation from its own context window.
pub fn setModel(self: *Agent, model: models.Model) void {
    self.model = model;
}

/// Run one user turn, streaming output through `handler`.
pub fn run(self: *Agent, user_text: []const u8, handler: anytype) !void {
    const base = self.messages.items.len;
    errdefer self.messages.shrinkRetainingCapacity(base);
    try self.appendUser(user_text);
    var round: usize = 0;
    while (round < rounds_max) : (round += 1) {
        var stream: provider.Stream = undefined;
        try self.client.send(&stream, .{
            .model = self.model.name,
            .tokens_max = self.model.tokens_max,
            .system = self.system,
            .messages = self.messages.items,
            .tools = &tool.specs,
        });
        defer stream.deinit();

        if (!stream.ok()) return self.reportAndReset(handler, stream.errorText(), base);
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
    const blocks = try arena.alloc(llm.Block, 1);
    blocks[0] = .{ .text = try arena.dupe(u8, text) };
    try self.messages.append(self.gpa, .{ .role = .user, .blocks = blocks });
}

/// Fold one assistant message's usage into the session totals and cost.
fn recordUsage(self: *Agent, usage: llm.Usage) void {
    self.stats.cost += self.model.cost(usage);
    self.stats.saved += self.model.savings(usage);
    self.stats.last = usage;
}

/// Consume one streamed assistant message: record it, run its tools, and queue
/// the results. Returns true when tools ran and another round is needed.
fn consume(self: *Agent, stream: *provider.Stream, handler: anytype) !bool {
    const arena = self.arena.allocator();
    var blocks: std.ArrayList(llm.Block) = .empty;
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
            if (in_tool) try flushTool(arena, &blocks, .{ .id = tool_id, .name = tool_name }, &input);
            tool_id = try arena.dupe(u8, use.id);
            tool_name = try arena.dupe(u8, use.name);
            input.clearRetainingCapacity();
            in_tool = true;
        },
        .input_json => |chunk| try input.appendSlice(self.gpa, chunk),
        .stop => |stop| {
            self.recordUsage(stop.usage);
            try handler.onUsage(self.stats);
        },
    };
    try flushText(arena, &blocks, &text);
    if (in_tool) try flushTool(arena, &blocks, .{ .id = tool_id, .name = tool_name }, &input);

    const reply = try blocks.toOwnedSlice(arena);
    try self.messages.append(self.gpa, .{ .role = .assistant, .blocks = reply });

    const context: tool.Context = .{ .gpa = self.gpa, .io = self.io };
    var results: std.ArrayList(llm.Block) = .empty;
    for (reply) |block| switch (block) {
        .tool_use => |use| {
            try handler.onToolStart(use.name, use.input_json);
            const result = try tool.run(&context, use.name, use.input_json);
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
    blocks: *std.ArrayList(llm.Block),
    text: *std.ArrayList(u8),
) !void {
    if (text.items.len == 0) return;
    try blocks.append(arena, .{ .text = try arena.dupe(u8, text.items) });
    text.clearRetainingCapacity();
}

fn flushTool(
    arena: std.mem.Allocator,
    blocks: *std.ArrayList(llm.Block),
    use: struct { id: []const u8, name: []const u8 },
    input: *std.ArrayList(u8),
) !void {
    try blocks.append(arena, .{ .tool_use = .{
        .id = use.id,
        .name = use.name,
        .input_json = try arena.dupe(u8, input.items),
    } });
}
