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
const Steering = @import("Steering.zig");
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
/// The active account's transport, or null while signed out (no account has a
/// usable credential). `run` requires a client; the app refuses to start a turn
/// while signed out, so the internal uses assume one.
client: ?provider.Client,
model: models.Model,
system: []const u8,
effort: llm.Effort,
retry: net.Retry,
arena: std.heap.ArenaAllocator,
items: std.ArrayList(llm.Item),
stats: Stats,
/// Steering messages the user submitted mid-turn, drained into the running turn
/// at each round boundary. Thread-safe: the UI thread pushes, the worker takes.
steering: Steering,
/// A stable per-session key sent to providers that route prompt-cache lookups by
/// it (OpenAI); generated once at init so every turn in the session shares it.
cache_key: [32]u8,

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
/// The concurrent runner reads `name`/`input_json` and writes `result`; the
/// collector reads the rest once the task has finished.
const Call = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
    result: anyerror!tool.Result = undefined,
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: ?provider.Client,
    options: struct { model: models.Model, system: []const u8, retry: net.Retry, effort: llm.Effort = .none },
) Agent {
    var seed: [16]u8 = undefined;
    io.random(&seed);
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .model = options.model,
        .system = options.system,
        .effort = options.effort,
        .retry = options.retry,
        .arena = .init(gpa),
        .items = .empty,
        .stats = .{},
        .steering = Steering.init(gpa, io),
        .cache_key = std.fmt.bytesToHex(seed, .lower),
    };
}

pub fn deinit(self: *Agent) void {
    self.items.deinit(self.gpa);
    self.steering.deinit();
    self.arena.deinit();
}

/// Switch the active account and model together; takes effect on the next turn.
/// The client carries both the provider transport and the account whose reasoning
/// blobs replay, so an account change and a model change are one atomic step — a
/// model can never be paired with a foreign vendor's client. History is untouched:
/// the new account reads the same conversation, dropping any reasoning it did not
/// itself produce.
pub fn switchTo(self: *Agent, client: provider.Client, model: models.Model) void {
    self.client = client;
    self.model = model;
}

/// Drop the active account, leaving the agent signed out. `model` is kept as the
/// last-shown value; a later `switchTo` restores a client before the next turn.
pub fn signOut(self: *Agent) void {
    self.client = null;
}

/// Switch the reasoning-effort level; takes effect on the next turn.
pub fn setEffort(self: *Agent, effort: llm.Effort) void {
    self.effort = effort;
}

/// Run one user turn, streaming output through `handler`.
pub fn run(self: *Agent, user_text: []const u8, handler: anytype) !void {
    if (self.client == null) return error.SignedOut;
    const base = self.items.items.len;
    errdefer self.items.shrinkRetainingCapacity(base);
    try self.appendUser(user_text);
    var round: usize = 0;
    while (round < rounds_max) : (round += 1) {
        const reply = (try self.fetchReply(handler, base)) orelse return;
        const ran_tools = try self.runTools(reply, handler);
        // Fold any mid-turn steering into this turn before the next round; when
        // the model asked for no tools, a steering message keeps the turn going
        // rather than ending it, so the message still lands mid-turn.
        const steered = try self.drainSteering(handler);
        if (!ran_tools and !steered) return;
    }
    return error.TooManyToolRounds;
}

/// Deliver every queued steering message into the running turn: combine them
/// into one user message (blank-line separated), append it to history, and
/// report it. Returns whether anything was delivered.
fn drainSteering(self: *Agent, handler: anytype) !bool {
    const pending = try self.steering.take();
    defer {
        for (pending) |message| self.gpa.free(message);
        self.gpa.free(pending);
    }
    if (pending.len == 0) return false;
    const combined = try Steering.join(self.gpa, pending);
    defer self.gpa.free(combined);
    try self.appendUser(combined);
    try handler.onSteering(combined, pending.len);
    return true;
}

/// Stream one assistant reply, retrying the whole request on a transient failure
/// (timeout, premature stream end, network fault, or retryable status). Only whole
/// requests are safe to retry, so a failed attempt's partial reply is discarded
/// here (history is
/// left untouched) and `handler.onStreamReset` clears any partial output before
/// the next attempt. Returns the reply's items (already appended to history), or
/// null when a non-retryable error was reported and the turn ends.
fn fetchReply(self: *Agent, handler: anytype, base: usize) !?[]const llm.Item {
    const model = self.model;
    const request: llm.Request = .{
        .model = model.name,
        .tokens_max = model.tokens_max,
        .system = self.system,
        .items = self.items.items,
        .tools = &tool.specs,
        .effort = self.effort,
        .cache_key = &self.cache_key,
    };
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (attempt > 1) try handler.onStreamReset();
        var stream: provider.Stream = undefined;
        self.client.?.send(&stream, request) catch |err| {
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

/// Whether a transport error is worth retrying: a timeout, premature stream end,
/// or transient network fault. A user cancel or channel close is never retried.
fn retryableError(err: anyerror) bool {
    return switch (err) {
        error.Timeout,
        error.IncompleteReply,
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

/// Surface a failed turn to the handler and drop its items so the history is
/// restored to the turn's start for the next turn.
fn reportAndReset(self: *Agent, handler: anytype, text: []const u8, base: usize) !void {
    self.items.shrinkRetainingCapacity(base);
    try handler.onError(text);
}

fn appendUser(self: *Agent, text: []const u8) !void {
    const arena = self.arena.allocator();
    try self.items.append(self.gpa, .{ .message = .{ .role = .user, .text = try arena.dupe(u8, text) } });
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
/// appending its items to history; returns that run of items. A stream or API
/// error returns before the append, so history stays untouched and the whole
/// request can be retried without a duplicated or partial message. The returned
/// slice is arena-owned, so it stays valid while `runTools` appends `tool_result`
/// items to the history list.
fn readReply(
    self: *Agent,
    model: *const models.Model,
    stream: anytype,
    handler: anytype,
) ![]const llm.Item {
    const arena = self.arena.allocator();
    // Tag reasoning with the account that produced it, so a serializer replays
    // its blobs only for the exact same account and drops any other whole.
    const origin = self.client.?.account();
    var items: std.ArrayList(llm.Item) = .empty;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.gpa);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(self.gpa);
    var tool_id: []const u8 = "";
    var tool_name: []const u8 = "";
    var in_tool = false;
    var thinking: std.ArrayList(u8) = .empty;
    defer thinking.deinit(self.gpa);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(self.gpa);
    var reasoning_id: std.ArrayList(u8) = .empty;
    defer reasoning_id.deinit(self.gpa);
    var in_thinking = false;
    var maybe_usage: ?llm.Usage = null;

    while (try stream.next()) |event| switch (event) {
        .thinking => |chunk| {
            in_thinking = true;
            if (chunk.id.len != 0) try setId(self.gpa, &reasoning_id, chunk.id);
            try thinking.appendSlice(self.gpa, chunk.text);
            try handler.onThinking(chunk.text);
        },
        // The blob closes the reasoning run; mark it open so a run that carried
        // only a blob (omitted reasoning) still round-trips.
        .thinking_blob => |chunk| {
            in_thinking = true;
            if (chunk.id.len != 0) try setId(self.gpa, &reasoning_id, chunk.id);
            try blob.appendSlice(self.gpa, chunk.blob);
        },
        .thinking_redacted => |chunk| {
            try flushThinking(arena, &items, &thinking, &blob, &reasoning_id, &in_thinking, origin);
            try items.append(arena, .{ .reasoning = .{
                .text = "",
                .blob = try arena.dupe(u8, chunk.blob),
                .redacted = true,
                .id = try arena.dupe(u8, chunk.id),
                .origin = origin,
            } });
            // The payload is encrypted, so stand a placeholder in for the display.
            try handler.onThinking(redacted_notice);
        },
        .text => |delta| {
            try flushThinking(arena, &items, &thinking, &blob, &reasoning_id, &in_thinking, origin);
            try text.appendSlice(self.gpa, delta);
            try handler.onText(delta);
        },
        .tool_use => |use| {
            // Commit the buffered items in stream order — the pending tool
            // first, then the reasoning/answer that streamed after it — so the
            // stored run keeps the order the model produced (reasoning at the
            // head, which the provider requires; tool and text calls interleaved
            // as sent).
            if (in_tool) try flushTool(arena, &items, .{ .id = tool_id, .name = tool_name }, &input);
            try flushThinking(arena, &items, &thinking, &blob, &reasoning_id, &in_thinking, origin);
            try flushText(arena, &items, &text);
            tool_id = try arena.dupe(u8, use.call_id);
            tool_name = try arena.dupe(u8, use.name);
            input.clearRetainingCapacity();
            in_tool = true;
        },
        .input_json => |chunk| try input.appendSlice(self.gpa, chunk),
        .stop => |stop| {
            maybe_usage = stop.usage;
            break;
        },
    };
    const usage = maybe_usage orelse return error.IncompleteReply;
    self.recordUsage(model, usage);
    try handler.onUsage(self.stats);

    // Flush what streamed after the last tool in the order the intra-turn branch
    // uses: the pending tool first, then any trailing reasoning and answer.
    if (in_tool) try flushTool(arena, &items, .{ .id = tool_id, .name = tool_name }, &input);
    try flushThinking(arena, &items, &thinking, &blob, &reasoning_id, &in_thinking, origin);
    try flushText(arena, &items, &text);

    const reply = try items.toOwnedSlice(arena);
    try self.items.appendSlice(self.gpa, reply);
    return reply;
}

/// The concurrent read-only task body, one monomorphization per `Dispatch` type
/// so the real turn loop keeps a direct call rather than an indirect one.
fn Runner(comptime Dispatch: type) type {
    return struct {
        fn run(call: *Call, context: *const tool.Context) void {
            call.result = Dispatch.run(context, call.name, call.input_json);
        }
    };
}

/// Run the assistant's tool calls through the real tool registry.
fn runTools(self: *Agent, reply: []const llm.Item, handler: anytype) !bool {
    return self.runToolsWith(tool, reply, handler);
}

/// Run every tool the assistant asked for, then queue the results in call order so
/// each `tool_result` maps back to its `tool_call` by `call_id`. `Dispatch` names
/// the tool source (`mutates` and `run`); the turn loop passes the real registry,
/// and tests inject controllable tools into this same scheduling path.
///
/// Each contiguous run of read-only calls runs concurrently through the group. A
/// mutating call is a barrier: it awaits every earlier read, runs alone, and
/// completes before any later call starts, so no mutation overlaps a read or
/// another mutation and call order gives a coherent filesystem view. Returns
/// false when the reply asked for no tools. A failing mutation (a mid-turn cancel
/// included) aborts the turn at once, before any later call runs; a cancel
/// observed while awaiting read-only calls aborts the same way. On every early
/// exit the errdefer reaps the group's in-flight tasks first.
fn runToolsWith(
    self: *Agent,
    comptime Dispatch: type,
    reply: []const llm.Item,
    handler: anytype,
) !bool {
    var count: usize = 0;
    for (reply) |item| switch (item) {
        .tool_call => count += 1,
        else => {},
    };
    if (count == 0) return false;

    const calls = try self.gpa.alloc(Call, count);
    defer self.gpa.free(calls);
    var index: usize = 0;
    for (reply) |item| switch (item) {
        .tool_call => |call| {
            calls[index] = .{ .id = call.call_id, .name = call.name, .input_json = call.arguments_json };
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
        if (Dispatch.mutates(call.name)) {
            // Drain earlier reads so the mutation can't race a concurrent read,
            // then reuse the emptied group for the reads that follow.
            try group.await(self.io);
            group = .init;
            call.result = try Dispatch.run(&context, call.name, call.input_json);
        } else {
            try group.concurrent(self.io, Runner(Dispatch).run, .{ call, &context });
        }
        dispatched += 1;
    }
    try group.await(self.io);

    const arena = self.arena.allocator();
    const results = try arena.alloc(llm.Item, count);
    while (collected < count) : (collected += 1) {
        const call = &calls[collected];
        const result = try call.result;
        try handler.onToolResult(call.name, result.content, result.is_error);
        results[collected] = .{ .tool_result = .{
            .call_id = try arena.dupe(u8, call.id),
            .content = try arena.dupe(u8, result.content),
            .is_error = result.is_error,
        } };
        self.gpa.free(result.content);
    }

    try self.items.appendSlice(self.gpa, results);
    return true;
}

/// Replace the open reasoning run's item id with `id` (the provider's
/// server-assigned reasoning-item id; empty and unused for Anthropic).
fn setId(gpa: std.mem.Allocator, reasoning_id: *std.ArrayList(u8), id: []const u8) !void {
    reasoning_id.clearRetainingCapacity();
    try reasoning_id.appendSlice(gpa, id);
}

fn flushText(
    arena: std.mem.Allocator,
    items: *std.ArrayList(llm.Item),
    text: *std.ArrayList(u8),
) !void {
    if (text.items.len == 0) return;
    try items.append(arena, .{ .message = .{ .role = .assistant, .text = try arena.dupe(u8, text.items) } });
    text.clearRetainingCapacity();
}

/// Commit the open reasoning run as one reasoning item (text plus its verbatim
/// blob and item id), preserving the head-of-message order the provider
/// validates. A no-op when no run is open.
fn flushThinking(
    arena: std.mem.Allocator,
    items: *std.ArrayList(llm.Item),
    thinking: *std.ArrayList(u8),
    blob: *std.ArrayList(u8),
    reasoning_id: *std.ArrayList(u8),
    in_thinking: *bool,
    origin: llm.Account,
) !void {
    if (!in_thinking.*) return;
    try items.append(arena, .{ .reasoning = .{
        .text = try arena.dupe(u8, thinking.items),
        .blob = try arena.dupe(u8, blob.items),
        .id = try arena.dupe(u8, reasoning_id.items),
        .origin = origin,
    } });
    thinking.clearRetainingCapacity();
    blob.clearRetainingCapacity();
    reasoning_id.clearRetainingCapacity();
    in_thinking.* = false;
}

fn flushTool(
    arena: std.mem.Allocator,
    items: *std.ArrayList(llm.Item),
    use: struct { id: []const u8, name: []const u8 },
    input: *std.ArrayList(u8),
) !void {
    try items.append(arena, .{ .tool_call = .{
        .call_id = use.id,
        .name = use.name,
        .arguments_json = try arena.dupe(u8, input.items),
    } });
}

test retryableError {
    try std.testing.expect(retryableError(error.Timeout));
    try std.testing.expect(retryableError(error.IncompleteReply));
    try std.testing.expect(retryableError(error.ConnectionResetByPeer));
    try std.testing.expect(!retryableError(error.Canceled));
    try std.testing.expect(!retryableError(error.Closed));
    try std.testing.expect(!retryableError(error.OutOfMemory));
}

test "usage is attributed to the model that produced it across a switch" {
    const gpa = std.testing.allocator;
    const sonnet = models.get(.anthropic, "claude-sonnet-4-6").?;
    const opus = models.get(.anthropic, "claude-opus-4-8").?;
    const client = provider.Client.init(gpa, std.testing.io, .{ .anthropic_subscription = undefined }, .{});
    var agent = Agent.init(gpa, std.testing.io, client, .{
        .model = sonnet,
        .system = "",
        .retry = .{},
    });
    defer agent.deinit();

    const one_million: llm.Usage = .{ .input = 1_000_000 };

    // `self.model` is opus, but this message was produced by sonnet. Pricing must
    // follow the passed model ($3, sonnet), not `self.model` ($5, opus).
    agent.switchTo(client, opus);
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
    terminal_error: ?anyerror = null,

    fn next(self: *ScriptedStream) !?llm.Event {
        if (self.index == self.events.len) {
            if (self.terminal_error) |terminal_error| return terminal_error;
            return null;
        }
        defer self.index += 1;
        return self.events[self.index];
    }
};

const SteerHandler = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn deinit(self: *SteerHandler) void {
        self.text.deinit(self.gpa);
    }

    fn onSteering(self: *SteerHandler, text: []const u8, count: usize) !void {
        try self.text.appendSlice(self.gpa, text);
        self.count = count;
    }
};

test "steering is delivered as one combined user message" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: SteerHandler = .{ .gpa = gpa };
    defer handler.deinit();

    try agent.steering.push("a");
    try agent.steering.push("b");
    try std.testing.expect(try agent.drainSteering(&handler));

    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[0].message.role);
    try std.testing.expectEqualStrings("a\n\nb", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("a\n\nb", handler.text.items);
    try std.testing.expectEqual(@as(usize, 2), handler.count);

    // An empty queue delivers nothing.
    try std.testing.expect(!try agent.drainSteering(&handler));
}

test "steering appends a separate user item, leaving grouping to the serializer" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: SteerHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A trailing user item, as a round's tool results would leave it. The Agent
    // appends a separate user item; the Anthropic serializer merges the run into
    // one message envelope.
    try agent.appendUser("tool results");
    try agent.steering.push("steer");
    try std.testing.expect(try agent.drainSteering(&handler));

    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[0].message.role);
    try std.testing.expectEqualStrings("tool results", agent.items.items[0].message.text);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[1].message.role);
    try std.testing.expectEqualStrings("steer", agent.items.items[1].message.text);
}

const CaptureHandler = struct {
    gpa: std.mem.Allocator,
    thinking: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    usage_count: usize = 0,
    tool_start_count: usize = 0,
    tool_result_count: usize = 0,

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
        self.usage_count += 1;
    }

    fn onToolStart(self: *CaptureHandler, name: []const u8, input_json: []const u8) !void {
        _ = name;
        _ = input_json;
        self.tool_start_count += 1;
    }

    fn onToolResult(
        self: *CaptureHandler,
        name: []const u8,
        content: []const u8,
        is_error: bool,
    ) !void {
        _ = name;
        _ = content;
        _ = is_error;
        self.tool_result_count += 1;
    }
};

fn scriptedAgent(gpa: std.mem.Allocator) Agent {
    const model = models.get(.anthropic, "claude-opus-4-8").?;
    const client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_subscription = undefined },
        .{},
    );
    return Agent.init(gpa, std.testing.io, client, .{
        .model = model,
        .system = "",
        .retry = .{},
    });
}

fn openaiScriptedAgent(gpa: std.mem.Allocator) Agent {
    const model = models.get(.openai, "gpt-5.6-sol").?;
    const client = provider.Client.init(gpa, std.testing.io, .{ .openai_api = "sk-test" }, .{});
    return Agent.init(gpa, std.testing.io, client, .{ .model = model, .system = "", .retry = .{} });
}

fn anthropicStream(io: std.Io, reader: *std.Io.Reader, idle_ms: u64) provider.Stream {
    var stream: provider.Stream = .{ .anthropic_subscription = undefined };
    stream.anthropic_subscription.gpa = std.testing.allocator;
    stream.anthropic_subscription.io = io;
    stream.anthropic_subscription.idle_ms = idle_ms;
    stream.anthropic_subscription.body = reader;
    stream.anthropic_subscription.parsed = null;
    stream.anthropic_subscription.terminal_delta = null;
    stream.anthropic_subscription.usage = .{};
    return stream;
}

fn openaiStream(io: std.Io, reader: *std.Io.Reader) provider.Stream {
    var stream: provider.Stream = .{ .openai_api = undefined };
    stream.openai_api.gpa = std.testing.allocator;
    stream.openai_api.io = io;
    stream.openai_api.idle_ms = 60_000;
    stream.openai_api.body = reader;
    stream.openai_api.parsed = null;
    stream.openai_api.usage = .{};
    return stream;
}

fn expectIncompleteToolStream(
    agent: *Agent,
    stream: *provider.Stream,
    handler: *CaptureHandler,
) !void {
    const maybe_reply: ?[]const llm.Item =
        agent.readReply(&agent.model, stream, handler) catch |err| switch (err) {
            error.IncompleteReply => null,
            else => return err,
        };
    if (maybe_reply) |reply| _ = try agent.runTools(reply, handler);

    try std.testing.expect(maybe_reply == null);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "readReply stops before a post-completion timeout" {
    const events = [_]llm.Event{
        .{ .text = "done" },
        .{ .stop = .{ .reason = "end_turn", .usage = .{ .output = 4 } } },
    };
    var stream: ScriptedStream = .{ .events = &events, .terminal_error = error.Timeout };
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
}

test "readReply accepts Anthropic message_stop without waiting for later traffic" {
    const body =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\"," ++
        "\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
        "data: {\"type\":\"message_delta\"," ++
        "\"delta\":{\"stop_reason\":\"end_turn\"}," ++
        "\"usage\":{\"output_tokens\":4}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n" ++
        "data: {\"type\":\"ping\"}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = anthropicStream(threaded.io(), &reader, 0);
    defer if (stream.anthropic_subscription.parsed) |parsed| parsed.deinit();
    defer if (stream.anthropic_subscription.terminal_delta) |terminal_delta| terminal_delta.deinit();
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(u64, 10), agent.stats.last.input);
    try std.testing.expectEqual(@as(u64, 4), agent.stats.last.output);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "message_stop") == null);
    try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "ping") != null);
}

test "readReply accepts OpenAI completion without consuming its done sentinel" {
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}\n\n" ++
        "data: {\"type\":\"response.completed\"," ++
        "\"response\":{\"status\":\"completed\",\"usage\":" ++
        "{\"input_tokens\":10,\"output_tokens\":4}}}\n\n" ++
        "data: [DONE]\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = openaiStream(threaded.io(), &reader);
    defer if (stream.openai_api.parsed) |parsed| parsed.deinit();
    var agent = openaiScriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(u64, 10), agent.stats.last.input);
    try std.testing.expectEqual(@as(u64, 4), agent.stats.last.output);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "[DONE]") != null);
}

test "readReply rejects provider EOF before text completion" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    {
        const body =
            "data: {\"type\":\"content_block_delta\"," ++
            "\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = anthropicStream(threaded.io(), &reader, 60_000);
        defer if (stream.anthropic_subscription.parsed) |parsed| parsed.deinit();
        defer if (stream.anthropic_subscription.terminal_delta) |terminal_delta| terminal_delta.deinit();
        var agent = scriptedAgent(std.testing.allocator);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
        defer handler.deinit();

        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), handler.usage_count);
    }

    {
        const body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(threaded.io(), &reader);
        defer if (stream.openai_api.parsed) |parsed| parsed.deinit();
        var agent = openaiScriptedAgent(std.testing.allocator);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
        defer handler.deinit();

        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), handler.usage_count);
    }
}

test "incomplete provider tool calls never enter history or execute" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    {
        const body =
            "data: {\"type\":\"content_block_start\",\"content_block\":" ++
            "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"nope\"}}\n\n" ++
            "data: {\"type\":\"content_block_delta\",\"delta\":" ++
            "{\"type\":\"input_json_delta\",\"partial_json\":\"{\"}}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = anthropicStream(threaded.io(), &reader, 60_000);
        defer if (stream.anthropic_subscription.parsed) |parsed| parsed.deinit();
        defer if (stream.anthropic_subscription.terminal_delta) |terminal_delta| terminal_delta.deinit();
        var agent = scriptedAgent(std.testing.allocator);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
        defer handler.deinit();

        try expectIncompleteToolStream(&agent, &stream, &handler);
    }

    {
        const body =
            "data: {\"type\":\"response.output_item.added\",\"item\":" ++
            "{\"type\":\"function_call\",\"call_id\":\"t1\"," ++
            "\"name\":\"nope\"}}\n\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\"}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(threaded.io(), &reader);
        defer if (stream.openai_api.parsed) |parsed| parsed.deinit();
        var agent = openaiScriptedAgent(std.testing.allocator);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
        defer handler.deinit();

        try expectIncompleteToolStream(&agent, &stream, &handler);
    }
}

test "readReply assembles a reasoning run, answer, and tool call in stream order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = .{ .text = "weigh " } },
        .{ .thinking = .{ .text = "it" } },
        .{ .thinking_blob = .{ .blob = "sig" } },
        .{ .text = "answer" },
        .{ .tool_use = .{ .call_id = "t1", .name = "read" } },
        .{ .input_json = "{\"path\":\"a\"}" },
        .{ .stop = .{ .reason = "tool_use", .usage = .{ .output = 5 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expectEqualStrings("weigh it", reply[0].reasoning.text);
    try std.testing.expectEqualStrings("sig", reply[0].reasoning.blob);
    try std.testing.expect(!reply[0].reasoning.redacted);
    try std.testing.expectEqual(llm.Account.anthropic_subscription, reply[0].reasoning.origin);
    try std.testing.expectEqualStrings("answer", reply[1].message.text);
    try std.testing.expectEqualStrings("t1", reply[2].tool_call.call_id);
    try std.testing.expectEqualStrings("read", reply[2].tool_call.name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", reply[2].tool_call.arguments_json);
    try std.testing.expectEqualStrings("weigh it", handler.thinking.items);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expectEqual(@as(u64, 5), agent.stats.last.output);
}

test "readReply keeps a redacted block and a signature-only run in order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking_redacted = .{ .blob = "enc" } },
        .{ .thinking_blob = .{ .blob = "sigonly" } },
        .{ .text = "hi" },
        .{ .stop = .{ .reason = "end_turn", .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expect(reply[0].reasoning.redacted);
    try std.testing.expectEqualStrings("enc", reply[0].reasoning.blob);
    try std.testing.expect(!reply[1].reasoning.redacted);
    try std.testing.expectEqualStrings("", reply[1].reasoning.text);
    try std.testing.expectEqualStrings("sigonly", reply[1].reasoning.blob);
    try std.testing.expectEqualStrings("hi", reply[2].message.text);
    try std.testing.expectEqualStrings(redacted_notice, handler.thinking.items);
}

test "readReply commits trailing text after the final tool in stream order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .tool_use = .{ .call_id = "t1", .name = "read" } },
        .{ .input_json = "{}" },
        .{ .text = "after" },
        .{ .stop = .{ .reason = "end_turn", .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings("t1", reply[0].tool_call.call_id);
    try std.testing.expectEqualStrings("after", reply[1].message.text);
}

test "readReply threads a stream-assigned reasoning-item id into the item" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Anthropic sends no reasoning id, but the plumbing must carry one when a
    // provider does (OpenAI's server-assigned `reasoning.id`, replayed under
    // `store:false`). A scripted stream stands in for that provider.
    const events = [_]llm.Event{
        .{ .thinking = .{ .id = "rs_1", .text = "hmm" } },
        .{ .thinking_blob = .{ .id = "rs_1", .blob = "enc" } },
        .{ .text = "done" },
        .{ .stop = .{ .reason = "end_turn", .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.id);
    try std.testing.expectEqualStrings("hmm", reply[0].reasoning.text);
    try std.testing.expectEqualStrings("enc", reply[0].reasoning.blob);
    try std.testing.expectEqualStrings("done", reply[1].message.text);
}

test "readReply tags reasoning with the active provider as origin" {
    const gpa = std.testing.allocator;
    // An openai-backed agent must stamp its reasoning items with its own account,
    // not an Anthropic one, or the openai serializer would drop them as foreign.
    const client = provider.Client.init(gpa, std.testing.io, .{ .openai_api = "sk-test" }, .{});
    var agent = Agent.init(gpa, std.testing.io, client, .{
        .model = models.get(.openai, "gpt-5.6-sol").?,
        .system = "",
        .retry = .{},
    });
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = .{ .id = "rs_1", .text = "hmm" } },
        .{ .thinking_blob = .{ .id = "rs_1", .blob = "enc" } },
        .{ .text = "done" },
        .{ .stop = .{ .reason = "completed", .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(llm.Account.openai_api, reply[0].reasoning.origin);
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.id);
}

// A scheduling seam that wraps a real threaded executor to observe tool ordering.
// It counts read-only tasks launched into the group but not yet awaited
// (`outstanding`), records their peak, and flags whether a mutation ran while any
// read was still outstanding. `groupConcurrent`, the inline mutation (through
// `probe.run`), and `groupAwait` all execute on the thread driving
// `runToolsWith`, so these counters carry no data race.
const ScheduleLog = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    outstanding: usize = 0,
    outstanding_peak: usize = 0,
    mutation_overlap: bool = false,
    // When set, the next group await reports cancellation without draining, so the
    // caller's errdefer must reap the launched reads through `cancelGroup`.
    cancel_at_await: bool = false,

    fn init(backend: std.Io) ScheduleLog {
        var vtable = backend.vtable.*;
        vtable.groupConcurrent = concurrent;
        vtable.groupAwait = awaitGroup;
        vtable.groupCancel = cancelGroup;
        return .{ .backend = backend, .vtable = vtable };
    }

    fn io(self: *ScheduleLog) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn recordMutation(self: *ScheduleLog) void {
        if (self.outstanding > 0) self.mutation_overlap = true;
    }

    fn concurrent(
        userdata: ?*anyopaque,
        group: *std.Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) std.Io.ConcurrentError!void {
        const self: *ScheduleLog = @ptrCast(@alignCast(userdata));
        try self.backend.vtable.groupConcurrent(
            self.backend.userdata,
            group,
            context,
            context_alignment,
            start,
        );
        self.outstanding += 1;
        self.outstanding_peak = @max(self.outstanding_peak, self.outstanding);
    }

    fn awaitGroup(
        userdata: ?*anyopaque,
        group: *std.Io.Group,
        token: *anyopaque,
    ) std.Io.Cancelable!void {
        const self: *ScheduleLog = @ptrCast(@alignCast(userdata));
        if (self.cancel_at_await) {
            self.cancel_at_await = false;
            return error.Canceled;
        }
        try self.backend.vtable.groupAwait(self.backend.userdata, group, token);
        self.outstanding = 0;
    }

    fn cancelGroup(userdata: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
        const self: *ScheduleLog = @ptrCast(@alignCast(userdata));
        self.backend.vtable.groupCancel(self.backend.userdata, group, token);
        self.outstanding = 0;
    }
};

// A controllable tool source for `runToolsWith`: "write" mutates, everything else
// is read-only. A mutation notes any scheduling overlap through the wrapped io;
// every call returns a trivial owned result.
const probe = struct {
    fn mutates(name: []const u8) bool {
        return std.mem.eql(u8, name, "write");
    }

    fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
        _ = input_json;
        if (mutates(name)) {
            const log: *ScheduleLog = @ptrCast(@alignCast(context.io.userdata));
            log.recordMutation();
        }
        return .{ .content = try context.gpa.dupe(u8, "ok"), .is_error = false };
    }
};

test "a mutating call is a barrier between the reads around it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var log: ScheduleLog = .init(threaded.io());

    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Two reads, then a mutation, then a read: the leading reads run concurrently,
    // the mutation must drain them before it runs, and the trailing read starts
    // only after the mutation completes.
    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "r1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r2", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r3", .name = "read", .arguments_json = "{}" } },
    };
    try std.testing.expect(try agent.runToolsWith(probe, &reply, &handler));

    // The mutation never ran while a read was still outstanding...
    try std.testing.expect(!log.mutation_overlap);
    // ...yet the two leading reads were in flight together.
    try std.testing.expectEqual(@as(usize, 2), log.outstanding_peak);

    // Results stay in call order, one per call.
    try std.testing.expectEqual(@as(usize, 4), agent.items.items.len);
    try std.testing.expectEqualStrings("r1", agent.items.items[0].tool_result.call_id);
    try std.testing.expectEqualStrings("r2", agent.items.items[1].tool_result.call_id);
    try std.testing.expectEqualStrings("w1", agent.items.items[2].tool_result.call_id);
    try std.testing.expectEqualStrings("r3", agent.items.items[3].tool_result.call_id);
    try std.testing.expectEqual(@as(usize, 4), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 4), handler.tool_result_count);
}

test "a cancel at the barrier reaps launched reads and starts nothing after it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var log: ScheduleLog = .init(threaded.io());
    log.cancel_at_await = true;

    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "r1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r3", .name = "read", .arguments_json = "{}" } },
    };
    // Inject cancellation at the barrier await (without draining) to force the
    // errdefer's live-task reap path -- the path a real mid-batch early exit takes
    // while a read is still in flight: the launched read is reaped and its result
    // freed exactly once (the leak-checking allocator proves it), the mutation
    // never runs, and the trailing read never starts.
    try std.testing.expectError(
        error.Canceled,
        agent.runToolsWith(probe, &reply, &handler),
    );
    try std.testing.expect(!log.mutation_overlap);
    // r1 and the w1 barrier were announced; r3, past the cancelled barrier, was not.
    try std.testing.expectEqual(@as(usize, 2), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}
