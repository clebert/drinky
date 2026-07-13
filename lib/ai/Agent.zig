//! Drives one user turn to completion: append the message, stream the model's
//! reply, run the tools it calls (independent calls concurrently), feed the
//! results back, and repeat until the model stops asking for tools. Owns the
//! conversation history and talks to the model through a neutral
//! `provider.Client`; presentation is delegated to a
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

/// One scheduled tool call: the reply it answers and the slot its task fills.
/// `runCall` reads `name`/`input_json` and writes `result`; the collector reads
/// the rest once the task has finished.
const Call = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
    result: anyerror!tool.Result = undefined,
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

    return self.runTools(reply, handler);
}

/// Run one call to completion into its slot. Spawned per call, so it touches only
/// its own `call` and the shared read-only `context` (a thread-safe gpa and io).
fn runCall(call: *Call, context: *const tool.Context) void {
    call.result = tool.run(context, call.name, call.input_json);
}

/// Run every tool the assistant asked for, then queue the results in call order so
/// each `tool_result` maps back to its `tool_use` id. Read-only calls run
/// concurrently through the group; mutating calls run inline in call order, so two
/// writes/edits to the same file can't race or lose an update within one turn.
/// Returns false when the reply asked for no tools. A failing mutation (a
/// mid-turn cancel included) aborts the turn at once, before any later call runs;
/// a cancel observed while awaiting the read-only calls aborts the same way. On
/// every early exit the errdefer reaps the group's in-flight tasks first.
fn runTools(self: *Agent, reply: []const llm.Block, handler: anytype) !bool {
    var count: usize = 0;
    for (reply) |block| switch (block) {
        .tool_use => count += 1,
        else => {},
    };
    if (count == 0) return false;

    const calls = try self.gpa.alloc(Call, count);
    defer self.gpa.free(calls);
    var index: usize = 0;
    for (reply) |block| switch (block) {
        .tool_use => |use| {
            calls[index] = .{ .id = use.id, .name = use.name, .input_json = use.input_json };
            index += 1;
        },
        else => {},
    };

    const context: tool.Context = .{ .gpa = self.gpa, .io = self.io };
    var group: std.Io.Group = .init;
    var dispatched: usize = 0;
    var collected: usize = 0;
    // On any early exit, cancel and reap the group (interrupting running tools),
    // then free the results of every finished-but-uncollected call.
    errdefer {
        group.cancel(self.io);
        for (calls[collected..dispatched]) |call| {
            const result = call.result catch continue;
            self.gpa.free(result.content);
        }
    }

    for (calls) |*call| {
        try handler.onToolStart(call.name, call.input_json);
        if (tool.mutates(call.name))
            call.result = try tool.run(&context, call.name, call.input_json)
        else
            try group.concurrent(self.io, runCall, .{ call, &context });
        dispatched += 1;
    }
    try group.await(self.io);

    const arena = self.arena.allocator();
    const results = try arena.alloc(llm.Block, count);
    while (collected < count) : (collected += 1) {
        const call = &calls[collected];
        const result = try call.result;
        try handler.onToolResult(call.name, result.content, result.is_error);
        results[collected] = .{ .tool_result = .{
            .tool_use_id = try arena.dupe(u8, call.id),
            .content = try arena.dupe(u8, result.content),
            .is_error = result.is_error,
        } };
        self.gpa.free(result.content);
    }

    try self.messages.append(self.gpa, .{ .role = .user, .blocks = results });
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
