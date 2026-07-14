//! Drives one user turn to completion: append the message, stream the model's
//! reply, run the tools it calls (independent calls concurrently), feed the
//! results back, and repeat until the model stops asking for tools. Owns the
//! conversation history and talks to the model through a neutral
//! `provider.Client`; presentation is delegated to a
//! `handler` with
//! `onText`/`onThinking`/`onToolStart`/`onToolResult`/`onUsage`/`onError`.

const std = @import("std");

const llm = @import("llm.zig");
const models = @import("models.zig");
const net = @import("net.zig");
const provider = @import("provider.zig");
const tool = @import("tool/root.zig");

const Agent = @This();

const rounds_max = 50;

/// Placeholder surfaced for a redacted reasoning block, whose real content is
/// encrypted and cannot be shown.
const redacted_notice = "[redacted thinking]";

/// Distinct models one session breaks its cost down by. Comfortably exceeds the
/// compiled model table; a rarer overflow drops only the per-model detail, never
/// the cumulative totals.
const by_model_max = 16;

gpa: std.mem.Allocator,
io: std.Io,
client: provider.Client,
model: models.Model,
system: []const u8,
effort: llm.Effort,
retry: net.Retry,
arena: std.heap.ArenaAllocator,
messages: std.ArrayList(llm.Message),
stats: Stats,

/// Cumulative dollar cost and cache savings over the session, plus the most
/// recent message's usage for the cache-hit and context-window gauges. Each
/// message is priced against the model that produced it, so the running totals —
/// and the per-model breakdown — stay correct across a mid-session `/model`
/// switch. A plain value type: the fixed `by_model` array copies cleanly across
/// the UI channel with the rest of the struct.
pub const Stats = struct {
    cost: f64 = 0,
    saved: f64 = 0,
    last: llm.Usage = .{},
    by_model: [by_model_max]ByModel = [_]ByModel{.{}} ** by_model_max,
    model_count: usize = 0,

    /// Cost, cache savings, and accumulated tokens billed to one model this
    /// session. `name` points into the compiled model table (static lifetime).
    pub const ByModel = struct {
        name: []const u8 = "",
        cost: f64 = 0,
        saved: f64 = 0,
        usage: llm.Usage = .{},
    };

    /// Attribute one message's cost, savings, and usage to `name`, opening a
    /// bucket the first time a model appears. Past `by_model_max` distinct models
    /// the per-model detail is dropped; the cumulative totals stay complete.
    fn attribute(self: *Stats, name: []const u8, cost: f64, saved: f64, usage: llm.Usage) void {
        const entry = self.entryFor(name) orelse return;
        entry.cost += cost;
        entry.saved += saved;
        entry.usage = entry.usage.plus(usage);
    }

    fn entryFor(self: *Stats, name: []const u8) ?*ByModel {
        for (self.by_model[0..self.model_count]) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        if (self.model_count == self.by_model.len) return null;
        const entry = &self.by_model[self.model_count];
        entry.* = .{ .name = name };
        self.model_count += 1;
        return entry;
    }
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
    options: struct { model: models.Model, system: []const u8, retry: net.Retry, effort: llm.Effort = .off },
) Agent {
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .model = options.model,
        .system = options.system,
        .effort = options.effort,
        .retry = options.retry,
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

/// Switch the reasoning-effort level; takes effect on the next turn.
pub fn setEffort(self: *Agent, effort: llm.Effort) void {
    self.effort = effort;
}

/// Run one user turn, streaming output through `handler`.
pub fn run(self: *Agent, user_text: []const u8, handler: anytype) !void {
    const base = self.messages.items.len;
    errdefer self.messages.shrinkRetainingCapacity(base);
    try self.appendUser(user_text);
    var round: usize = 0;
    while (round < rounds_max) : (round += 1) {
        const reply = (try self.fetchReply(handler, base)) orelse return;
        if (!try self.runTools(reply, handler)) return;
    }
    return error.TooManyToolRounds;
}

/// Stream one assistant reply, retrying the whole request on a transient failure
/// (timeout, network fault, or a retryable status). Only whole requests are safe
/// to retry, so a failed attempt's partial reply is discarded here (history is
/// left untouched) and `handler.onStreamReset` clears any partial output before
/// the next attempt. Returns the reply's blocks (already appended to history), or
/// null when a non-retryable error was reported and the turn ends.
fn fetchReply(self: *Agent, handler: anytype, base: usize) !?[]const llm.Block {
    const model = self.model;
    const request: llm.Request = .{
        .model = model.name,
        .tokens_max = model.tokens_max,
        .system = self.system,
        .messages = self.messages.items,
        .tools = &tool.specs,
        .effort = self.effort,
    };
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (attempt > 1) try handler.onStreamReset();
        var stream: provider.Stream = undefined;
        self.client.send(&stream, request) catch |err| {
            if (retryableError(err) and attempt < self.retry.attempts_max) {
                try self.backoff(attempt, 0);
                continue;
            }
            return err;
        };
        defer stream.deinit();

        if (!stream.ok()) {
            if (stream.retryable() and attempt < self.retry.attempts_max) {
                try self.backoff(attempt, stream.retryAfterMs() orelse 0);
                continue;
            }
            try self.reportAndReset(handler, stream.errorText(), base);
            return null;
        }
        const reply = self.readReply(&model, &stream, handler) catch |err| switch (err) {
            error.ApiError => {
                try self.reportAndReset(handler, stream.errorText(), base);
                return null;
            },
            error.Canceled, error.Closed => return err,
            else => {
                if (retryableError(err) and attempt < self.retry.attempts_max) {
                    try self.backoff(attempt, 0);
                    continue;
                }
                return err;
            },
        };
        return reply;
    }
}

/// Wait before the retry following a failed `attempt`: the server's `retry-after`
/// when it gave one, else an exponential backoff. A cancel during the wait aborts
/// the turn.
fn backoff(self: *Agent, attempt: u32, suggested_ms: u64) !void {
    const delay_ms = if (suggested_ms > 0) suggested_ms else self.retry.delayMs(attempt);
    const bounded: u64 = @min(delay_ms, std.math.maxInt(i64));
    try self.io.sleep(.fromMilliseconds(@intCast(bounded)), .awake);
}

/// Whether a transport error is worth retrying: a timeout or a transient network
/// fault. A user cancel or a channel close is never retried.
fn retryableError(err: anyerror) bool {
    return switch (err) {
        error.Timeout,
        error.ReadFailed,
        error.WriteFailed,
        error.EndOfStream,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.TlsConnectionTruncated,
        => true,
        else => false,
    };
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

/// Fold one assistant message's usage into the session totals, priced with
/// `model` — the model that produced the message, threaded from the request so
/// billing can't drift when a later `/model` switch changes `self.model`.
fn recordUsage(self: *Agent, model: *const models.Model, usage: llm.Usage) void {
    const cost = model.cost(&usage);
    const saved = model.savings(&usage);
    self.stats.cost += cost;
    self.stats.saved += saved;
    self.stats.last = usage;
    self.stats.attribute(model.name, cost, saved, usage);
}

/// Read one streamed assistant message to completion, recording usage and
/// appending it to history; returns its blocks. A stream or API error returns
/// before the append, so history stays untouched and the whole request can be
/// retried without a duplicated or partial message.
fn readReply(
    self: *Agent,
    model: *const models.Model,
    stream: anytype,
    handler: anytype,
) ![]const llm.Block {
    const arena = self.arena.allocator();
    var blocks: std.ArrayList(llm.Block) = .empty;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.gpa);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(self.gpa);
    var tool_id: []const u8 = "";
    var tool_name: []const u8 = "";
    var in_tool = false;
    var thinking: std.ArrayList(u8) = .empty;
    defer thinking.deinit(self.gpa);
    var signature: std.ArrayList(u8) = .empty;
    defer signature.deinit(self.gpa);
    var in_thinking = false;

    while (try stream.next()) |event| switch (event) {
        .thinking => |delta| {
            in_thinking = true;
            try thinking.appendSlice(self.gpa, delta);
            try handler.onThinking(delta);
        },
        // The signature closes the reasoning run; mark it open so a block that
        // carried only a signature (omitted reasoning) still round-trips.
        .thinking_signature => |delta| {
            in_thinking = true;
            try signature.appendSlice(self.gpa, delta);
        },
        .thinking_redacted => |data| {
            try flushThinking(arena, &blocks, &thinking, &signature, &in_thinking);
            try blocks.append(arena, .{ .thinking = .{
                .text = "",
                .signature = try arena.dupe(u8, data),
                .redacted = true,
            } });
            // The payload is encrypted, so stand a placeholder in for the display.
            try handler.onThinking(redacted_notice);
        },
        .text => |delta| {
            try flushThinking(arena, &blocks, &thinking, &signature, &in_thinking);
            try text.appendSlice(self.gpa, delta);
            try handler.onText(delta);
        },
        .tool_use => |use| {
            // Commit the buffered blocks in stream order — the pending tool
            // first, then the reasoning/answer that streamed after it — so the
            // stored message keeps the order the model produced (thinking at the
            // head, which the provider requires; tool and text calls interleaved
            // as sent).
            if (in_tool) try flushTool(arena, &blocks, .{ .id = tool_id, .name = tool_name }, &input);
            try flushThinking(arena, &blocks, &thinking, &signature, &in_thinking);
            try flushText(arena, &blocks, &text);
            tool_id = try arena.dupe(u8, use.id);
            tool_name = try arena.dupe(u8, use.name);
            input.clearRetainingCapacity();
            in_tool = true;
        },
        .input_json => |chunk| try input.appendSlice(self.gpa, chunk),
        .stop => |stop| {
            self.recordUsage(model, stop.usage);
            try handler.onUsage(self.stats);
        },
    };
    // Flush what streamed after the last tool in the order the intra-turn branch
    // uses: the pending tool first, then any trailing reasoning and answer.
    if (in_tool) try flushTool(arena, &blocks, .{ .id = tool_id, .name = tool_name }, &input);
    try flushThinking(arena, &blocks, &thinking, &signature, &in_thinking);
    try flushText(arena, &blocks, &text);

    const reply = try blocks.toOwnedSlice(arena);
    try self.messages.append(self.gpa, .{ .role = .assistant, .blocks = reply });
    return reply;
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

/// Commit the open reasoning run as one thinking block (text plus its verbatim
/// signature), preserving the head-of-message order the provider validates. A
/// no-op when no run is open.
fn flushThinking(
    arena: std.mem.Allocator,
    blocks: *std.ArrayList(llm.Block),
    thinking: *std.ArrayList(u8),
    signature: *std.ArrayList(u8),
    in_thinking: *bool,
) !void {
    if (!in_thinking.*) return;
    try blocks.append(arena, .{ .thinking = .{
        .text = try arena.dupe(u8, thinking.items),
        .signature = try arena.dupe(u8, signature.items),
    } });
    thinking.clearRetainingCapacity();
    signature.clearRetainingCapacity();
    in_thinking.* = false;
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

test retryableError {
    try std.testing.expect(retryableError(error.Timeout));
    try std.testing.expect(retryableError(error.ConnectionResetByPeer));
    try std.testing.expect(!retryableError(error.Canceled));
    try std.testing.expect(!retryableError(error.Closed));
    try std.testing.expect(!retryableError(error.OutOfMemory));
}

test "usage is attributed to the model that produced it across a switch" {
    const gpa = std.testing.allocator;
    const sonnet = models.get(.anthropic, "claude-sonnet-4-6").?;
    const opus = models.get(.anthropic, "claude-opus-4-8").?;
    const client = provider.Client.init(.anthropic, gpa, std.testing.io, undefined, .{});
    var agent = Agent.init(gpa, std.testing.io, client, .{
        .model = sonnet,
        .system = "",
        .retry = .{},
    });
    defer agent.deinit();

    const one_million: llm.Usage = .{ .input = 1_000_000 };

    // `self.model` is opus, but this message was produced by sonnet. Pricing must
    // follow the passed model ($3, sonnet), not `self.model` ($5, opus).
    agent.setModel(opus);
    agent.recordUsage(&sonnet, one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.by_model[0].cost, 1e-9);

    // An opus turn. Cumulative now blends both rates: sonnet $3 + opus $5.
    agent.recordUsage(&opus, one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 8), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), agent.stats.model_count);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.stats.by_model[0].name);
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.stats.by_model[1].name);
    try std.testing.expectApproxEqAbs(@as(f64, 5), agent.stats.by_model[1].cost, 1e-9);

    // A second sonnet turn folds into the existing bucket, not a third one.
    agent.recordUsage(&sonnet, one_million);
    try std.testing.expectEqual(@as(usize, 2), agent.stats.model_count);
    try std.testing.expectApproxEqAbs(@as(f64, 6), agent.stats.by_model[0].cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 2_000_000), agent.stats.by_model[0].usage.input);
}

const ScriptedStream = struct {
    events: []const llm.Event,
    index: usize = 0,

    fn next(self: *ScriptedStream) !?llm.Event {
        if (self.index == self.events.len) return null;
        defer self.index += 1;
        return self.events[self.index];
    }
};

const CaptureHandler = struct {
    gpa: std.mem.Allocator,
    thinking: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    usage_seen: bool = false,

    fn deinit(self: *CaptureHandler) void {
        self.thinking.deinit(self.gpa);
        self.text.deinit(self.gpa);
    }

    fn onThinking(self: *CaptureHandler, delta: []const u8) !void {
        try self.thinking.appendSlice(self.gpa, delta);
    }

    fn onText(self: *CaptureHandler, delta: []const u8) !void {
        try self.text.appendSlice(self.gpa, delta);
    }

    fn onUsage(self: *CaptureHandler, stats: Stats) !void {
        _ = stats;
        self.usage_seen = true;
    }
};

fn scriptedAgent(gpa: std.mem.Allocator) Agent {
    const model = models.get(.anthropic, "claude-opus-4-8").?;
    const client = provider.Client.init(.anthropic, gpa, std.testing.io, undefined, .{});
    return Agent.init(gpa, std.testing.io, client, .{ .model = model, .system = "", .retry = .{} });
}

test "readReply assembles a reasoning run, answer, and tool call in stream order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = "weigh " },
        .{ .thinking = "it" },
        .{ .thinking_signature = "sig" },
        .{ .text = "answer" },
        .{ .tool_use = .{ .id = "t1", .name = "read" } },
        .{ .input_json = "{\"path\":\"a\"}" },
        .{ .stop = .{ .reason = "tool_use", .usage = .{ .output = 5 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expectEqualStrings("weigh it", reply[0].thinking.text);
    try std.testing.expectEqualStrings("sig", reply[0].thinking.signature);
    try std.testing.expect(!reply[0].thinking.redacted);
    try std.testing.expectEqualStrings("answer", reply[1].text);
    try std.testing.expectEqualStrings("t1", reply[2].tool_use.id);
    try std.testing.expectEqualStrings("read", reply[2].tool_use.name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", reply[2].tool_use.input_json);
    try std.testing.expectEqualStrings("weigh it", handler.thinking.items);
    try std.testing.expect(handler.usage_seen);
    try std.testing.expectEqual(@as(u64, 5), agent.stats.last.output);
}

test "readReply keeps a redacted block and a signature-only run in order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking_redacted = "enc" },
        .{ .thinking_signature = "sigonly" },
        .{ .text = "hi" },
        .{ .stop = .{ .reason = "end_turn", .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expect(reply[0].thinking.redacted);
    try std.testing.expectEqualStrings("enc", reply[0].thinking.signature);
    try std.testing.expect(!reply[1].thinking.redacted);
    try std.testing.expectEqualStrings("", reply[1].thinking.text);
    try std.testing.expectEqualStrings("sigonly", reply[1].thinking.signature);
    try std.testing.expectEqualStrings("hi", reply[2].text);
    try std.testing.expectEqualStrings(redacted_notice, handler.thinking.items);
}

test "readReply commits trailing text after the final tool in stream order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .tool_use = .{ .id = "t1", .name = "read" } },
        .{ .input_json = "{}" },
        .{ .text = "after" },
        .{ .stop = .{ .reason = "end_turn", .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings("t1", reply[0].tool_use.id);
    try std.testing.expectEqualStrings("after", reply[1].text);
}
