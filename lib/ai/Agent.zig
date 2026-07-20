//! Drives one user turn to completion: append the message, stream the reply,
//! run the tools it calls, feed the results back, and repeat until the model
//! stops asking for tools. Owns the conversation history; talks to the model
//! through a neutral `provider.Client` and delegates presentation to a handler.

const std = @import("std");

const llm = @import("llm.zig");
const models = @import("models.zig");
const net = @import("net.zig");
const provider = @import("provider.zig");
const Steering = @import("Steering.zig");
const tool = @import("tool/root.zig");

const Agent = @This();

const rounds_max = 50;

/// Placeholder shown for a redacted reasoning block (its content is encrypted).
const redacted_notice = "[redacted thinking]";

/// Distinct models one session breaks its cost down by; an overflow drops only
/// the per-model detail, never the cumulative totals.
const by_model_max = 16;

gpa: std.mem.Allocator,
io: std.Io,
/// The active account's transport, or null while signed out. The app refuses to
/// start a turn while signed out, so the internal uses assume one.
client: ?provider.Client,
model: models.Model,
system: []const u8,
effort: llm.Effort,
retry: net.Retry,
items: std.ArrayList(llm.Item),
stats: Stats,
/// Steering messages the user submitted mid-turn, drained into the running turn
/// at each round boundary. Thread-safe: the UI thread pushes, the worker takes.
steering: Steering,
/// Stable per-session prompt-cache routing key (used by OpenAI); generated once
/// at init so every turn shares it.
cache_key: [32]u8,

/// Cumulative session cost and cache savings, plus the last message's usage for
/// the gauges. Each message is priced against the model that produced it, so the
/// totals stay correct across a mid-session `/model` switch. A plain value type:
/// it copies whole across the UI channel.
pub const Stats = struct {
    cost: f64 = 0,
    saved: f64 = 0,
    last: llm.Usage = .{},
    by_model: [by_model_max]ByModel = [_]ByModel{.{}} ** by_model_max,
    model_count: usize = 0,

    /// One model's session totals; `name` points into the compiled model table
    /// (static lifetime).
    pub const ByModel = struct {
        name: []const u8 = "",
        cost: f64 = 0,
        saved: f64 = 0,
        usage: llm.Usage = .{},
    };

    /// Attribute one message to `name`, opening a bucket on first appearance.
    fn attribute(
        self: *Stats,
        name: []const u8,
        cost: f64,
        saved: f64,
        usage: *const llm.Usage,
    ) void {
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

/// One scheduled tool call: the concurrent runner writes `result`; the collector
/// reads it once the task has finished.
const Call = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
    // A never-started task keeps this sentinel, so the errdefer's `catch
    // continue` skips it instead of reading an uninitialized result.
    result: anyerror!tool.Result = error.NotRun,
};

/// The production fetch: `provider.Client.send` on the active account. A seam
/// like `runToolsWith`'s `Dispatch`, so tests can script whole turns.
const ClientFetch = struct {
    client: *provider.Client,

    const Stream = provider.Stream;

    fn send(self: *ClientFetch, stream: *provider.Stream, request: *const llm.Request) !void {
        return self.client.send(stream, request);
    }
};

/// One streamed reply under assembly: the committed items plus the open answer,
/// reasoning-run, and tool-call buffers. Flush methods dupe each string before
/// the append and free every dupe if a later step fails, so a failure leaves no
/// orphaned allocation.
const Pending = struct {
    items: std.ArrayList(llm.Item) = .empty,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    blob: std.ArrayList(u8) = .empty,
    reasoning_id: std.ArrayList(u8) = .empty,
    in_thinking: bool = false,
    tool_id: std.ArrayList(u8) = .empty,
    tool_name: std.ArrayList(u8) = .empty,
    input: std.ArrayList(u8) = .empty,
    in_tool: bool = false,

    /// Frees the list backings only; the finished items belong to the caller.
    fn deinit(self: *Pending, gpa: std.mem.Allocator) void {
        inline for (@typeInfo(Pending).@"struct".fields) |field| {
            if (field.type != bool) @field(self, field.name).deinit(gpa);
        }
    }

    /// Commit the pending tool call and answer text ahead of a fresh reasoning
    /// run, keeping stream order.
    fn flushBeforeRun(self: *Pending, gpa: std.mem.Allocator) !void {
        if (self.in_tool) try self.flushTool(gpa);
        try self.flushText(gpa);
    }

    /// Commit everything buffered in stream order — the pending tool first, then
    /// the reasoning/answer that streamed after it — keeping the order the model
    /// produced, reasoning at the head as the provider requires.
    fn flushAll(self: *Pending, gpa: std.mem.Allocator, origin: llm.Account) !void {
        if (self.in_tool) try self.flushTool(gpa);
        try self.flushThinking(gpa, origin);
        try self.flushText(gpa);
    }

    fn flushText(self: *Pending, gpa: std.mem.Allocator) !void {
        if (self.text.items.len == 0) return;
        const text_copy = try gpa.dupe(u8, self.text.items);
        errdefer gpa.free(text_copy);
        try self.items.append(gpa, .{ .message = .{ .role = .assistant, .text = text_copy } });
        self.text.clearRetainingCapacity();
    }

    /// Commit the open reasoning run as one item (text plus its verbatim blob
    /// and item id); a no-op when no run is open.
    fn flushThinking(self: *Pending, gpa: std.mem.Allocator, origin: llm.Account) !void {
        if (!self.in_thinking) return;
        const text_copy = try gpa.dupe(u8, self.thinking.items);
        errdefer gpa.free(text_copy);
        const blob_copy = try gpa.dupe(u8, self.blob.items);
        errdefer gpa.free(blob_copy);
        const id_copy = try gpa.dupe(u8, self.reasoning_id.items);
        errdefer gpa.free(id_copy);
        try self.items.append(gpa, .{ .reasoning = .{
            .text = text_copy,
            .blob = blob_copy,
            .id = id_copy,
            .origin = origin,
        } });
        self.thinking.clearRetainingCapacity();
        self.blob.clearRetainingCapacity();
        self.reasoning_id.clearRetainingCapacity();
        self.in_thinking = false;
    }

    /// Commit one redacted reasoning block: its encrypted blob and item id,
    /// with empty visible text.
    fn appendRedacted(
        self: *Pending,
        gpa: std.mem.Allocator,
        chunk: llm.Event.Blob,
        origin: llm.Account,
    ) !void {
        const blob_copy = try gpa.dupe(u8, chunk.blob);
        errdefer gpa.free(blob_copy);
        const id_copy = try gpa.dupe(u8, chunk.id);
        errdefer gpa.free(id_copy);
        try self.items.append(gpa, .{ .reasoning = .{
            .text = "",
            .blob = blob_copy,
            .redacted = true,
            .id = id_copy,
            .origin = origin,
        } });
    }

    fn flushTool(self: *Pending, gpa: std.mem.Allocator) !void {
        const id_copy = try gpa.dupe(u8, self.tool_id.items);
        errdefer gpa.free(id_copy);
        const name_copy = try gpa.dupe(u8, self.tool_name.items);
        errdefer gpa.free(name_copy);
        const json_copy = try gpa.dupe(u8, self.input.items);
        errdefer gpa.free(json_copy);
        try self.items.append(gpa, .{ .tool_call = .{
            .call_id = id_copy,
            .name = name_copy,
            .arguments_json = json_copy,
        } });
        self.in_tool = false;
    }
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: ?provider.Client,
    options: struct {
        model: models.Model,
        system: []const u8,
        retry: net.Retry,
        effort: llm.Effort = .none,
    },
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
        .items = .empty,
        .stats = .{},
        .steering = Steering.init(gpa, io),
        .cache_key = std.fmt.bytesToHex(seed, .lower),
    };
}

pub fn deinit(self: *Agent) void {
    for (self.items.items) |item| freeItem(self.gpa, item);
    self.items.deinit(self.gpa);
    self.steering.deinit();
}

/// Switch account and model together, effective next turn. The client carries
/// both the transport and the reasoning-replay account, so the pair is one
/// atomic step — a model is never paired with a foreign vendor's client.
/// History is untouched; the new account drops reasoning it did not produce.
pub fn switchTo(self: *Agent, client: provider.Client, model: models.Model) void {
    self.client = client;
    self.model = model;
}

/// Drop the active account, leaving the agent signed out; `model` is kept as
/// the last-shown value.
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
    var fetch: ClientFetch = .{ .client = &self.client.? };
    return self.runWith(&fetch, user_text, handler);
}

fn runWith(self: *Agent, fetch: anytype, user_text: []const u8, handler: anytype) !void {
    const base = self.items.items.len;
    errdefer self.rollback(base);
    try self.appendUser(user_text);
    var round: usize = 0;
    while (round < rounds_max) : (round += 1) {
        const reply = (try self.fetchReply(fetch, handler, base)) orelse return;
        const ran_tools = try self.runTools(reply, handler);
        // Fold mid-turn steering in before the next round; with no tools asked,
        // a steering message keeps the turn going rather than ending it.
        const steered = try self.drainSteering(handler);
        if (!ran_tools and !steered) return;
    }
    return error.TooManyToolRounds;
}

/// Deliver every queued steering message as one combined user message, appended
/// to history and reported. Returns whether anything was delivered.
fn drainSteering(self: *Agent, handler: anytype) !bool {
    const pending = try self.steering.take();
    defer {
        for (pending) |message| self.gpa.free(message);
        self.gpa.free(pending);
    }
    if (pending.len == 0) return false;
    // A failure mid-delivery (a cancel included) returns the taken batch to the
    // queue, for the cancel path to hand back to the editor.
    errdefer for (pending) |message| self.steering.push(message) catch break;
    const combined = try Steering.join(self.gpa, pending);
    defer self.gpa.free(combined);
    try self.appendUser(combined);
    try handler.onSteering(combined, pending.len);
    return true;
}

/// Stream one assistant reply, retrying on transient failures. Only whole
/// requests are safe to retry, so a failed attempt's partial reply is discarded
/// (history untouched) and `handler.onStreamReset` clears partial output first.
/// Returns the reply's items (already appended to history), or null when a
/// non-retryable error was reported and the turn ends.
fn fetchReply(self: *Agent, fetch: anytype, handler: anytype, base: usize) !?[]const llm.Item {
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
        var stream: @TypeOf(fetch.*).Stream = undefined;
        fetch.send(&stream, &request) catch |err| {
            if (retryableError(err) and attempt < self.retry.attempts_max) {
                try self.backoff(.{ .attempt = attempt });
                continue;
            }
            return err;
        };
        defer stream.deinit();

        if (!stream.ok()) {
            if (stream.retryable() and attempt < self.retry.attempts_max) {
                try self.backoff(.{
                    .attempt = attempt,
                    .suggested_ms = stream.retryAfterMs() orelse 0,
                });
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
                    try self.backoff(.{ .attempt = attempt });
                    continue;
                }
                return err;
            },
        };
        return reply;
    }
}

/// Wait before the retry after a failed attempt: the server's `retry-after`
/// (capped) or exponential backoff. A cancel during the wait aborts the turn.
fn backoff(self: *Agent, failure: net.Retry.Failure) !void {
    const delay_ms = self.retry.backoffMs(failure);
    const bounded: u64 = @min(delay_ms, std.math.maxInt(i64));
    try self.io.sleep(.fromMilliseconds(@intCast(bounded)), .awake);
}

/// Transient transport faults worth retrying; a user cancel or channel close
/// never is.
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

/// Surface a failed turn to the handler, restoring history to the turn's start.
fn reportAndReset(self: *Agent, handler: anytype, text: []const u8, base: usize) !void {
    self.rollback(base);
    try handler.onError(text);
}

/// Free and drop every history item from `base` on; capacity is retained so a
/// rolled-back turn does not thrash the list backing.
fn rollback(self: *Agent, base: usize) void {
    for (self.items.items[base..]) |item| freeItem(self.gpa, item);
    self.items.shrinkRetainingCapacity(base);
}

/// Free one history item's owned strings; an empty string frees as a no-op.
fn freeItem(gpa: std.mem.Allocator, item: llm.Item) void {
    switch (item) {
        .message => |message| gpa.free(message.text),
        .reasoning => |reasoning| {
            gpa.free(reasoning.text);
            gpa.free(reasoning.blob);
            gpa.free(reasoning.id);
        },
        .tool_call => |call| {
            gpa.free(call.call_id);
            gpa.free(call.name);
            gpa.free(call.arguments_json);
        },
        .tool_result => |result| {
            gpa.free(result.call_id);
            gpa.free(result.content);
        },
    }
}

fn appendUser(self: *Agent, text: []const u8) !void {
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    try self.items.append(self.gpa, .{ .message = .{ .role = .user, .text = owned } });
}

/// Fold one message's usage into the totals, priced with `model` — threaded from
/// the request so billing can't drift when `/model` changes `self.model`.
fn recordUsage(self: *Agent, model: *const models.Model, usage: *const llm.Usage) void {
    const cost = model.cost(usage);
    const saved = model.savings(usage);
    self.stats.cost += cost;
    self.stats.saved += saved;
    self.stats.last = usage.*;
    self.stats.attribute(model.name, cost, saved, usage);
}

/// Read one streamed assistant message to completion, recording usage and
/// appending its items to history. The reply is built locally and committed only
/// once complete, so a stream or API error leaves history untouched and the
/// whole request can be retried without a duplicated or partial message. The
/// returned slice views the committed tail of `self.items`; it stays valid until
/// the next append (which `runTools` performs only after reading the reply).
fn readReply(
    self: *Agent,
    model: *const models.Model,
    stream: anytype,
    handler: anytype,
) ![]const llm.Item {
    const gpa = self.gpa;
    // Tag reasoning with the producing account, so a serializer replays blobs
    // only for that exact account.
    const origin = self.client.?.account();
    // The defer frees the buffer backings; the errdefer frees the finished items
    // only on failure, since a successful commit hands them to `self.items`.
    var state: Pending = .{};
    defer state.deinit(gpa);
    errdefer for (state.items.items) |item| freeItem(gpa, item);
    var maybe_usage: ?llm.Usage = null;

    while (try stream.next()) |event| switch (event) {
        .thinking => |chunk| {
            // A run with its blob, or a differing item id, is finished: commit
            // it so adjacent runs stay separate items.
            if (state.blob.items.len != 0 or newRunId(state.reasoning_id.items, chunk.id))
                try state.flushThinking(gpa, origin);
            if (!state.in_thinking) try state.flushBeforeRun(gpa);
            state.in_thinking = true;
            if (chunk.id.len != 0) try setBuffer(gpa, &state.reasoning_id, chunk.id);
            try state.thinking.appendSlice(gpa, chunk.text);
            try handler.onThinking(chunk.text);
        },
        // The blob closes the run; mark it open so a blob-only run round-trips.
        .thinking_blob => |chunk| {
            if (newRunId(state.reasoning_id.items, chunk.id))
                try state.flushThinking(gpa, origin);
            if (!state.in_thinking) try state.flushBeforeRun(gpa);
            state.in_thinking = true;
            if (chunk.id.len != 0) try setBuffer(gpa, &state.reasoning_id, chunk.id);
            try state.blob.appendSlice(gpa, chunk.blob);
        },
        .thinking_redacted => |chunk| {
            try state.flushThinking(gpa, origin);
            try state.appendRedacted(gpa, chunk, origin);
            try handler.onThinking(redacted_notice);
        },
        .text => |delta| {
            try state.flushThinking(gpa, origin);
            try state.text.appendSlice(gpa, delta);
            try handler.onText(delta);
        },
        .tool_use => |use| {
            try state.flushAll(gpa, origin);
            try setBuffer(gpa, &state.tool_id, use.call_id);
            try setBuffer(gpa, &state.tool_name, use.name);
            state.input.clearRetainingCapacity();
            state.in_tool = true;
        },
        .input_json => |chunk| try state.input.appendSlice(gpa, chunk),
        .stop => |stop| {
            maybe_usage = stop.usage;
            break;
        },
    };
    const usage = maybe_usage orelse return error.IncompleteReply;
    self.recordUsage(model, &usage);
    try handler.onUsage(self.stats);
    try state.flushAll(gpa, origin);

    const start = self.items.items.len;
    try self.items.appendSlice(gpa, state.items.items);
    return self.items.items[start..];
}

/// The concurrent read-only task body, monomorphized per `Dispatch` so the real
/// turn loop keeps a direct call.
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

/// Run every tool the assistant asked for, queuing results in call order so each
/// `tool_result` maps back to its `tool_call`. `Dispatch` names the tool source
/// (`mutates` and `run`); tests inject controllable tools into this same path.
///
/// Contiguous read-only calls run concurrently; a mutating call is a barrier —
/// it awaits every earlier read and runs alone, so no mutation overlaps a read
/// or another mutation and call order gives a coherent filesystem view. Any
/// failure (a mid-turn cancel included) aborts before any later call runs; the
/// errdefer reaps in-flight tasks first. Returns false when no tools were asked.
fn runToolsWith(
    self: *Agent,
    comptime Dispatch: type,
    reply: []const llm.Item,
    handler: anytype,
) !bool {
    var call_list: std.ArrayList(Call) = .empty;
    defer call_list.deinit(self.gpa);
    for (reply) |item| switch (item) {
        .tool_call => |call| try call_list.append(
            self.gpa,
            .{ .id = call.call_id, .name = call.name, .input_json = call.arguments_json },
        ),
        else => {},
    };
    // Stable from here on: nothing appends once the tasks hold pointers.
    const calls = call_list.items;
    if (calls.len == 0) return false;

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
            // Drain earlier reads so the mutation can't race one; the emptied
            // group is reused for the reads that follow.
            try group.await(self.io);
            group = .init;
            call.result = try Dispatch.run(&context, call.name, call.input_json);
        } else {
            try group.concurrent(self.io, Runner(Dispatch).run, .{ call, &context });
        }
        dispatched += 1;
    }
    try group.await(self.io);

    const results = try self.gpa.alloc(llm.Item, calls.len);
    defer self.gpa.free(results);
    errdefer for (results[0..collected]) |item| freeItem(self.gpa, item);
    while (collected < calls.len) : (collected += 1) {
        const call = &calls[collected];
        const result = try call.result;
        try handler.onToolResult(call.name, result.content, result.is_error);
        const call_id = try self.gpa.dupe(u8, call.id);
        errdefer self.gpa.free(call_id);
        const content = try self.gpa.dupe(u8, result.content);
        errdefer self.gpa.free(content);
        results[collected] = .{ .tool_result = .{
            .call_id = call_id,
            .content = content,
            .is_error = result.is_error,
        } };
        self.gpa.free(result.content);
    }

    try self.items.appendSlice(self.gpa, results);
    return true;
}

/// Replace `buffer`'s contents with `bytes`, retaining its capacity.
fn setBuffer(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), bytes: []const u8) !void {
    buffer.clearRetainingCapacity();
    try buffer.appendSlice(gpa, bytes);
}

/// Whether an incoming chunk's item id names a different reasoning item than
/// the open run's, marking a run boundary. An empty id (Anthropic) never does.
fn newRunId(current: []const u8, incoming: []const u8) bool {
    return current.len != 0 and incoming.len != 0 and !std.mem.eql(u8, current, incoming);
}

test retryableError {
    try std.testing.expect(retryableError(error.Timeout));
    try std.testing.expect(retryableError(error.IncompleteReply));
    try std.testing.expect(retryableError(error.ConnectionResetByPeer));
    try std.testing.expect(!retryableError(error.Canceled));
    try std.testing.expect(!retryableError(error.Closed));
    try std.testing.expect(!retryableError(error.OutOfMemory));
    // An oversize stream reproduces on the same request, so it is not retried.
    try std.testing.expect(!retryableError(error.StreamResponseTooLarge));
}

test "usage is attributed to the model that produced it across a switch" {
    const gpa = std.testing.allocator;
    const sonnet = models.get(.anthropic, "claude-sonnet-4-6").?;
    const opus = models.get(.anthropic, "claude-opus-4-8").?;
    const client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_subscription = undefined },
        .{},
    );
    var agent = Agent.init(gpa, std.testing.io, client, .{
        .model = sonnet,
        .system = "",
        .retry = .{},
    });
    defer agent.deinit();

    const one_million: llm.Usage = .{ .input = 1_000_000 };

    // Produced by sonnet while `self.model` is opus: pricing must follow the
    // passed model ($3, sonnet), not `self.model` ($5, opus).
    agent.switchTo(client, opus);
    agent.recordUsage(&sonnet, &one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.by_model[0].cost, 1e-9);

    // An opus turn blends both rates: sonnet $3 + opus $5.
    agent.recordUsage(&opus, &one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 8), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), agent.stats.model_count);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.stats.by_model[0].name);
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.stats.by_model[1].name);
    try std.testing.expectApproxEqAbs(@as(f64, 5), agent.stats.by_model[1].cost, 1e-9);

    // A second sonnet turn folds into the existing bucket, not a third one.
    agent.recordUsage(&sonnet, &one_million);
    try std.testing.expectEqual(@as(usize, 2), agent.stats.model_count);
    try std.testing.expectApproxEqAbs(@as(f64, 6), agent.stats.by_model[0].cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 2_000_000), agent.stats.by_model[0].usage.input);
}

test "cumulative totals stay exact past the per-model bound" {
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();

    // The 17th model opens no bucket, yet the totals and last-usage gauge
    // still include it.
    const opus = models.get(.anthropic, "claude-opus-4-8").?;
    inline for (0..by_model_max + 1) |index| {
        var model = opus;
        model.name = std.fmt.comptimePrint("m{d}", .{index});
        agent.recordUsage(&model, &.{ .input = 1_000_000 });
    }
    try std.testing.expectEqual(@as(usize, by_model_max), agent.stats.model_count);
    try std.testing.expectEqualStrings("m15", agent.stats.by_model[by_model_max - 1].name);
    try std.testing.expectApproxEqAbs(@as(f64, 85), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 1_000_000), agent.stats.last.input);
}

const ScriptedStream = struct {
    events: []const llm.Event,
    index: usize = 0,
    terminal_error: ?anyerror = null,
    head_ok: bool = true,
    head_retryable: bool = false,
    retry_after_ms: ?u64 = null,
    error_text: []const u8 = "",

    fn next(self: *ScriptedStream) !?llm.Event {
        if (self.index == self.events.len) {
            if (self.terminal_error) |terminal_error| return terminal_error;
            return null;
        }
        defer self.index += 1;
        return self.events[self.index];
    }

    fn deinit(self: *ScriptedStream) void {
        _ = self;
    }

    fn ok(self: *const ScriptedStream) bool {
        return self.head_ok;
    }

    fn retryable(self: *const ScriptedStream) bool {
        return self.head_retryable;
    }

    fn retryAfterMs(self: *const ScriptedStream) ?u64 {
        return self.retry_after_ms;
    }

    fn errorText(self: *const ScriptedStream) []const u8 {
        return self.error_text;
    }
};

// A scripted fetch for `runWith`: each send consumes the next attempt (the last
// repeats), either failing outright or handing out a fresh copy of its stream.
const ScriptedFetch = struct {
    attempts: []const Attempt,
    sends: usize = 0,

    const Attempt = union(enum) { fail: anyerror, stream: ScriptedStream };
    const Stream = ScriptedStream;

    fn send(self: *ScriptedFetch, stream: *ScriptedStream, request: *const llm.Request) !void {
        _ = request;
        defer self.sends += 1;
        switch (self.attempts[@min(self.sends, self.attempts.len - 1)]) {
            .fail => |err| return err,
            .stream => |scripted| stream.* = scripted,
        }
    }
};

// An io seam that records each requested sleep in milliseconds and returns at
// once, so retry backoffs are observable without waiting them out.
const SleepLog = struct {
    vtable: std.Io.VTable,
    slept_ms: [8]u64 = undefined,
    count: usize = 0,

    fn init(backend: std.Io) SleepLog {
        var vtable = backend.vtable.*;
        vtable.sleep = sleep;
        return .{ .vtable = vtable };
    }

    fn io(self: *SleepLog) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *SleepLog = @ptrCast(@alignCast(userdata));
        self.slept_ms[self.count] = @intCast(timeout.duration.raw.toMilliseconds());
        self.count += 1;
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

    try std.testing.expect(!try agent.drainSteering(&handler));
}

test "steering appends a separate user item, leaving grouping to the serializer" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: SteerHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A trailing user item, as a round's tool results leave it: the Agent
    // appends a separate item; the Anthropic serializer merges the run.
    try agent.appendUser("tool results");
    try agent.steering.push("steer");
    try std.testing.expect(try agent.drainSteering(&handler));

    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[0].message.role);
    try std.testing.expectEqualStrings("tool results", agent.items.items[0].message.text);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[1].message.role);
    try std.testing.expectEqualStrings("steer", agent.items.items[1].message.text);
}

test "a cancel during steering delivery returns the taken batch to the queue" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    // A handler cancelled while reporting the batch: a mid-turn Esc racing the
    // round-boundary drain.
    const CancelHandler = struct {
        fn onSteering(self: *@This(), text: []const u8, count: usize) !void {
            _ = self;
            _ = text;
            _ = count;
            return error.Canceled;
        }
    };
    var handler: CancelHandler = .{};

    try agent.steering.push("a");
    try agent.steering.push("b");
    try std.testing.expectError(error.Canceled, agent.drainSteering(&handler));

    // The batch is back in the queue, in order, for cancel to return to the editor.
    const taken = try agent.steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 2), taken.len);
    try std.testing.expectEqualStrings("a", taken[0]);
    try std.testing.expectEqualStrings("b", taken[1]);
}

const CaptureHandler = struct {
    gpa: std.mem.Allocator,
    thinking: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    usage_count: usize = 0,
    tool_start_count: usize = 0,
    tool_result_count: usize = 0,
    stream_reset_count: usize = 0,
    steer_count: usize = 0,

    fn deinit(self: *CaptureHandler) void {
        self.thinking.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.errors.deinit(self.gpa);
    }

    fn onStreamReset(self: *CaptureHandler) !void {
        self.stream_reset_count += 1;
    }

    fn onError(self: *CaptureHandler, text: []const u8) !void {
        try self.errors.appendSlice(self.gpa, text);
    }

    fn onSteering(self: *CaptureHandler, text: []const u8, count: usize) !void {
        _ = text;
        self.steer_count += count;
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
    stream.anthropic_subscription.budget = .{ .max = net.stream_response_bytes_max };
    stream.anthropic_subscription.body = reader;
    stream.anthropic_subscription.parsed = null;
    stream.anthropic_subscription.terminal = false;
    stream.anthropic_subscription.usage = .{};
    return stream;
}

fn openaiStream(io: std.Io, reader: *std.Io.Reader) provider.Stream {
    var stream: provider.Stream = .{ .openai_api = undefined };
    stream.openai_api.gpa = std.testing.allocator;
    stream.openai_api.io = io;
    stream.openai_api.idle_ms = 60_000;
    stream.openai_api.budget = .{ .max = net.stream_response_bytes_max };
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
        .{ .stop = .{ .usage = .{ .output = 4 } } },
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

test "a failed reply attempt reclaims its transient allocations" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A large text chunk then a tool call, ending without a stop event: each
    // attempt allocates item memory and then fails.
    const big = "x" ** 4096;
    const events = [_]llm.Event{
        .{ .text = big },
        .{ .tool_use = .{ .call_id = "t1", .name = "read" } },
    };

    // One warm-up attempt settles the reusable capacities (the item list, the
    // handler buffers) so the measured window isolates per-attempt retention.
    handler.text.clearRetainingCapacity();
    var warmup: ScriptedStream = .{ .events = &events, .terminal_error = error.Timeout };
    try std.testing.expectError(error.Timeout, agent.readReply(&agent.model, &warmup, &handler));
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    const settled = failing.allocated_bytes - failing.freed_bytes;

    const attempts = 64;
    for (0..attempts) |_| {
        handler.text.clearRetainingCapacity();
        var stream: ScriptedStream = .{ .events = &events, .terminal_error = error.Timeout };
        try std.testing.expectError(
            error.Timeout,
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }

    // Retained bytes must not scale with attempts — a session-lifetime arena
    // would keep each attempt's items, adding at least `big` per attempt.
    const grew = (failing.allocated_bytes - failing.freed_bytes) - settled;
    try std.testing.expect(grew < big.len);
}

test "rollback frees every item appended since the base" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    try agent.appendUser("keep me");
    const base = agent.items.items.len;

    // A multi-string reply past the base: reasoning run, answer, and tool call.
    const events = [_]llm.Event{
        .{ .thinking = .{ .id = "rs_1", .text = "weigh it" } },
        .{ .thinking_blob = .{ .id = "rs_1", .blob = "sig" } },
        .{ .text = "answer" },
        .{ .tool_use = .{ .call_id = "t1", .name = "read" } },
        .{ .input_json = "{}" },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expect(agent.items.items.len > base);

    // Each appended item is freed exactly once (the leak-checking allocator
    // proves it); the user message stays.
    agent.rollback(base);
    try std.testing.expectEqual(base, agent.items.items.len);
    try std.testing.expectEqualStrings("keep me", agent.items.items[base - 1].message.text);
}

fn readReplyUnderOom(allocator: std.mem.Allocator) !void {
    var agent = scriptedAgent(allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = allocator };
    defer handler.deinit();

    // One reply exercising every multi-string item builder.
    const events = [_]llm.Event{
        .{ .thinking = .{ .id = "rs_1", .text = "weigh it" } },
        .{ .thinking_blob = .{ .id = "rs_1", .blob = "sig" } },
        .{ .thinking_redacted = .{ .id = "rs_2", .blob = "enc" } },
        .{ .text = "answer" },
        .{ .tool_use = .{ .call_id = "t1", .name = "read" } },
        .{ .input_json = "{\"path\":\"a\"}" },
        .{ .text = "trailing" },
        .{ .stop = .{ .usage = .{ .output = 5 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model, &stream, &handler);
}

test "readReply frees partial work at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readReplyUnderOom, .{});
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

test "readReply separates OpenAI reasoning summary parts with a blank line" {
    // Two summary parts share one reasoning item and arrive with no text between
    // them; the rising summary_index on the second part.added is the only seam,
    // so both the committed reply and the streamed handler must read "a\n\nb".
    const body =
        "data: {\"type\":\"response.reasoning_summary_part.added\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"rs_1\",\"delta\":\"a\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_part.added\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":1,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"rs_1\",\"delta\":\"b\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\"," ++
        "\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"enc\"}}\n\n" ++
        "data: {\"type\":\"response.completed\"," ++
        "\"response\":{\"status\":\"completed\",\"usage\":" ++
        "{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
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
    try std.testing.expectEqualStrings("a\n\nb", reply[0].reasoning.text);
    try std.testing.expectEqualStrings("enc", reply[0].reasoning.blob);
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.id);
    try std.testing.expectEqualStrings("a\n\nb", handler.thinking.items);
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
        .{ .stop = .{ .usage = .{ .output = 5 } } },
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
        .{ .stop = .{ .usage = .{} } },
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
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings("t1", reply[0].tool_call.call_id);
    try std.testing.expectEqualStrings("after", reply[1].message.text);
}

test "readReply keeps adjacent reasoning runs as separate items in stream order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Each run keeps its own blob and id, and the text stays between the runs
    // it streamed between rather than sinking below them.
    const events = [_]llm.Event{
        .{ .thinking = .{ .id = "rs_a", .text = "A" } },
        .{ .thinking_blob = .{ .id = "rs_a", .blob = "encA" } },
        .{ .thinking = .{ .id = "rs_b", .text = "B" } },
        .{ .thinking_blob = .{ .id = "rs_b", .blob = "encB" } },
        .{ .text = "between" },
        .{ .thinking = .{ .id = "rs_c", .text = "C" } },
        .{ .thinking_blob = .{ .id = "rs_c", .blob = "encC" } },
        .{ .tool_use = .{ .call_id = "t1", .name = "read" } },
        .{ .input_json = "{}" },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 5), reply.len);
    try std.testing.expectEqualStrings("A", reply[0].reasoning.text);
    try std.testing.expectEqualStrings("encA", reply[0].reasoning.blob);
    try std.testing.expectEqualStrings("rs_a", reply[0].reasoning.id);
    try std.testing.expectEqualStrings("B", reply[1].reasoning.text);
    try std.testing.expectEqualStrings("encB", reply[1].reasoning.blob);
    try std.testing.expectEqualStrings("rs_b", reply[1].reasoning.id);
    try std.testing.expectEqualStrings("between", reply[2].message.text);
    try std.testing.expectEqualStrings("C", reply[3].reasoning.text);
    try std.testing.expectEqualStrings("encC", reply[3].reasoning.blob);
    try std.testing.expectEqualStrings("rs_c", reply[3].reasoning.id);
    try std.testing.expectEqualStrings("t1", reply[4].tool_call.call_id);
}

test "readReply tags reasoning with the active provider as origin, threading its id" {
    const gpa = std.testing.allocator;
    // An openai-backed agent must stamp reasoning with its own account or the
    // serializer drops it as foreign; the reasoning id rides along for replay.
    var agent = openaiScriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = .{ .id = "rs_1", .text = "hmm" } },
        .{ .thinking_blob = .{ .id = "rs_1", .blob = "enc" } },
        .{ .text = "done" },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqual(llm.Account.openai_api, reply[0].reasoning.origin);
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.id);
    try std.testing.expectEqualStrings("hmm", reply[0].reasoning.text);
    try std.testing.expectEqualStrings("enc", reply[0].reasoning.blob);
    try std.testing.expectEqualStrings("done", reply[1].message.text);
}

// A scheduling seam wrapping a real threaded executor: counts read-only tasks
// launched but not yet awaited, records their peak, and flags a mutation running
// while a read was outstanding. Every hook executes on the thread driving
// `runToolsWith`, so the counters carry no data race.
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

// A controllable tool source for `runToolsWith`: "write" mutates, everything
// else is read-only; a mutation notes any scheduling overlap.
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

    // Two reads, a mutation, a read: the leading reads run concurrently, the
    // mutation drains them first, the trailing read starts only after it.
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
    // Cancel at the barrier await without draining, forcing the errdefer's
    // live-task reap: the launched read's result is freed exactly once, the
    // mutation never runs, and the trailing read never starts.
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

fn runToolsUnderOom(allocator: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var log: ScheduleLog = .init(threaded.io());

    var agent = scriptedAgent(allocator);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = allocator };
    defer handler.deinit();

    // All-mutation calls run inline (no task spawn), so the sweep of the
    // tool-result builder is deterministic under every injected failure.
    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w2", .name = "write", .arguments_json = "{}" } },
    };
    _ = try agent.runToolsWith(probe, &reply, &handler);
}

test "runTools frees partial work at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runToolsUnderOom, .{});
}

const tool_round_events = [_]llm.Event{
    .{ .tool_use = .{ .call_id = "t1", .name = "write" } },
    .{ .input_json = "{}" },
    .{ .stop = .{ .usage = .{} } },
};

const end_turn_events = [_]llm.Event{
    .{ .text = "hi" },
    .{ .stop = .{ .usage = .{} } },
};

test "run fails cleanly on round-bound overrun with the turn rolled back" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A model that asks for a tool every round overruns the bound after exactly
    // `rounds_max` rounds; the whole turn (user message included) is dropped.
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &tool_round_events } }},
    };
    try std.testing.expectError(error.TooManyToolRounds, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, rounds_max), fetch.sends);
    try std.testing.expectEqual(@as(usize, rounds_max), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "run commits a no-tool reply and ends the turn" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }} };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqualStrings("go", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("hi", agent.items.items[1].message.text);
    try std.testing.expectEqual(llm.Role.assistant, agent.items.items[1].message.role);
}

test "run retries transient failures, resetting the stream before each reattempt" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // attempts_max is 3: a connect failure, a mid-stream failure, then success.
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .fail = error.ConnectionRefused },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Timeout } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 3), fetch.sends);
    try std.testing.expectEqual(@as(usize, 2), handler.stream_reset_count);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqualStrings("hi", agent.items.items[1].message.text);
    try std.testing.expectEqualStrings("hi", handler.text.items);
}

test "run surfaces the failure once the attempt bound is exhausted" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{.{ .fail = error.Timeout }} };
    try std.testing.expectError(error.Timeout, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 3), fetch.sends);
    try std.testing.expectEqual(@as(usize, 2), handler.stream_reset_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "a retryable head's retry-after hint reaches backoff" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Without the hint the first backoff would be backoff_ms_initial (500ms).
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{
            .events = &.{},
            .head_ok = false,
            .head_retryable = true,
            .retry_after_ms = 5000,
        } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqual(@as(u64, 5000), log.slept_ms[0]);
    try std.testing.expectEqual(@as(usize, 1), handler.stream_reset_count);
    try std.testing.expectEqualStrings("hi", handler.text.items);
}

test "a mid-stream cancel propagates without a retry" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } }},
    };
    try std.testing.expectError(error.Canceled, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 0), handler.stream_reset_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "an API error reports onError, rolls the turn back, and ends it cleanly" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A committed tool round, then an API error frame: the whole turn unwinds.
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.ApiError, .error_text = "boom" } },
    } };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqualStrings("boom", handler.errors.items);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);

    // A failed non-retryable head takes the same clean-abort path.
    var head_fetch: ScriptedFetch = .{
        .attempts = &.{
            .{ .stream = .{ .events = &.{}, .head_ok = false, .error_text = "denied" } },
        },
    };
    try agent.runWith(&head_fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), head_fetch.sends);
    try std.testing.expectEqualStrings("boomdenied", handler.errors.items);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "steering queued when the model would stop keeps the turn alive" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const second_events = [_]llm.Event{
        .{ .text = "more" },
        .{ .stop = .{ .usage = .{} } },
    };
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &end_turn_events } },
        .{ .stream = .{ .events = &second_events } },
    } };
    try agent.steering.push("steer");
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), handler.steer_count);
    try std.testing.expectEqual(@as(usize, 4), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[2].message.role);
    try std.testing.expectEqualStrings("steer", agent.items.items[2].message.text);
    try std.testing.expectEqualStrings("more", agent.items.items[3].message.text);
}
