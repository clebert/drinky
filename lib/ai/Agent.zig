const std = @import("std");

const llm = @import("llm.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");
const provider = @import("provider.zig");
const Steering = @import("Steering.zig");
const testing = @import("testing.zig");
const tool = @import("tool/root.zig");

const Agent = @This();

const redacted_notice = "[redacted thinking]";
pub const tool_calls_max: usize = 64;
const read_only_calls_max: usize = 32;

pub const unfinished_tool_result =
    "The tool stopped before Drinky recorded a result. " ++
    "Drinky does not know if the tool changed the system.";

gpa: std.mem.Allocator,
io: std.Io,
environ: std.process.Environ,
client: ?provider.Client,
model: ?Model,
system: []const u8,
effort: llm.Effort,
retry: net.Retry,
rounds_max: usize = 1000,
bash: tool.Context.Bash,
document: []const u8,
skill_guard: ?*tool.SkillGuard,
items: std.ArrayList(llm.Item),
stats: Stats,
measured_context: ?MeasuredContext,
steering: Steering,
cache_key: [32]u8,

pub const Stats = struct {
    cost: f64 = 0,
    context_tokens: ?u64 = 0,
    cache_usage: llm.Usage = .{},
    quota: ?llm.Quota = null,
    quota_seen_ms: i64 = 0,
    credits: ?llm.Credits = null,

    fn forgetBilling(self: *Stats) void {
        self.quota = null;
        self.credits = null;
    }

    pub fn forgetTurnEvidence(self: *Stats) void {
        self.cache_usage = .{};
        self.quota_seen_ms = 0;
        self.forgetBilling();
    }
};

pub const ModelMismatch = struct {
    requested: []const u8,
    served: []const u8,
};

pub const RetryAttempt = struct {
    attempt: u32,
    cause: Cause,

    pub const Cause = union(enum) {
        failure: anyerror,
        response: []const u8,
    };
};

pub const Receipt = struct {
    history_base: usize,
    history_end: usize,
    steering_committed_count: usize,
    truncated: bool = false,
};

pub const Outcome = struct {
    receipt: Receipt,
    disposition: Disposition,

    pub const Disposition = union(enum) {
        completed,
        canceled,
        closed,
        credential_replaced,
        credential_rejected,
        failed: anyerror,
    };
};

const MeasuredContext = struct {
    tokens: u64,
    model: Model,
    account: llm.Account,
    reasoning: llm.Request.Reasoning,
};

const TurnState = struct {
    base: usize,
    checkpoint: usize,
    steering_committed_count: usize = 0,
    truncated: bool = false,
    pending_steering: ?[][]u8 = null,
    pending_context: ?MeasuredContext = null,
    presentation_closed: bool = false,
};

const Call = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
    result_index: usize = 0,
    result: State = .pending,
    moved: bool = false,

    const State = union(enum) {
        pending,
        finished: anyerror!tool.Result,
    };

    fn takeFinished(self: *Call) anyerror!tool.Result {
        const finished = switch (self.result) {
            .pending => unreachable,
            .finished => |result| result,
        };
        self.result = .pending;
        return finished;
    }
};

const ClientFetch = struct {
    client: *provider.Client,

    const Stream = provider.Stream;

    fn send(self: *ClientFetch, stream: *provider.Stream, request: *const llm.Request) !void {
        return self.client.send(stream, request);
    }

    fn renewCredential(self: *ClientFetch) !bool {
        return self.client.renewCredential();
    }

    fn fetchQuota(self: *ClientFetch) !?llm.Quota {
        return self.client.fetchQuota();
    }

    fn fetchCredits(self: *ClientFetch) !?llm.Credits {
        return self.client.fetchCredits();
    }
};

fn dupeOutput(
    gpa: std.mem.Allocator,
    account: llm.Account,
    output: *const llm.Event.Output,
    prior: []const llm.Item,
) !llm.Item {
    return switch (output.*) {
        .message => |text| message: {
            if (text.len == 0) return error.IncompleteReply;
            break :message .{ .message = .{
                .role = .assistant,
                .text = try gpa.dupe(u8, text),
            } };
        },
        .reasoning => |*reasoning| reasoning: {
            const replay = reasoning.replay(account) orelse return error.IncompleteReply;
            break :reasoning .{ .reasoning = .{ .replay = try replay.dupe(gpa) } };
        },
        .tool_call => |call| tool_call: {
            if (call.call_id.len == 0 or duplicateCallId(prior, call.call_id))
                return error.IncompleteReply;
            const arguments = if (call.arguments_json.len == 0) "{}" else call.arguments_json;
            if (!try objectJsonValid(gpa, arguments)) return error.IncompleteReply;
            const id_copy = try gpa.dupe(u8, call.call_id);
            errdefer gpa.free(id_copy);
            const name_copy = try gpa.dupe(u8, call.name);
            errdefer gpa.free(name_copy);
            const arguments_copy = try gpa.dupe(u8, arguments);
            break :tool_call .{ .tool_call = .{
                .call_id = id_copy,
                .name = name_copy,
                .arguments_json = arguments_copy,
            } };
        },
    };
}

fn objectJsonValid(gpa: std.mem.Allocator, bytes: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
    defer parsed.deinit();
    return parsed.value == .object;
}

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: ?provider.Client,
    options: struct {
        model: ?Model,
        system: []const u8,
        retry: net.Retry,
        environ: std.process.Environ,
        effort: llm.Effort = .low,
        bash: tool.Context.Bash = .{},
        document: []const u8 = "",
        skill_guard: ?*tool.SkillGuard = null,
    },
) Agent {
    return .{
        .gpa = gpa,
        .io = io,
        .environ = options.environ,
        .client = client,
        .model = options.model,
        .system = options.system,
        .effort = options.effort,
        .retry = options.retry,
        .bash = options.bash,
        .document = options.document,
        .skill_guard = options.skill_guard,
        .items = .empty,
        .stats = .{},
        .measured_context = null,
        .steering = Steering.init(gpa, io),
        .cache_key = generateCacheKey(io),
    };
}

pub fn deinit(self: *Agent) void {
    for (self.items.items) |item| freeItem(self.gpa, item);
    self.items.deinit(self.gpa);
    self.steering.deinit();
}

pub fn resetConversation(self: *Agent) void {
    self.rollback(0);
    self.stats = .{};
    self.measured_context = null;
    self.steering.clear();
    self.cache_key = generateCacheKey(self.io);
}

pub fn switchTo(self: *Agent, client: provider.Client, model: ?Model) void {
    const account_changed = if (self.client) |active|
        active.account() != client.account()
    else
        true;
    const model_changed = if (self.model) |active|
        if (model) |next| !active.eql(&next) else true
    else
        model != null;
    self.client = client;
    self.model = model;
    if (account_changed) self.stats.forgetBilling();
    if (account_changed or model_changed) self.stats.cache_usage = .{};
    self.refreshContext();
}

pub fn signOut(self: *Agent) void {
    self.client = null;
    self.stats.forgetBilling();
    self.stats.cache_usage = .{};
    self.refreshContext();
}

pub fn dropAccountEvidence(self: *Agent, account: llm.Account) void {
    self.dropReasoning(account);
    const client = self.client orelse return;
    if (client.account() == account) {
        self.stats.forgetBilling();
        self.stats.cache_usage = .{};
    }
}

pub fn producedBefore(self: *const Agent, account: llm.Account, index: usize) usize {
    std.debug.assert(index <= self.items.items.len);
    var count: usize = 0;
    for (self.items.items[0..index]) |item| {
        const reasoning = switch (item) {
            .reasoning => |value| value,
            else => continue,
        };
        count += @intFromBool(std.meta.activeTag(reasoning.replay) == account);
    }
    return count;
}

pub const HistorySpan = struct {
    base: usize,
    end: usize,
};

pub fn rewindHistory(self: *Agent, span: HistorySpan) void {
    std.debug.assert(span.base <= span.end);
    std.debug.assert(span.end == self.items.items.len);
    self.rollback(span.base);
    self.measured_context = null;
    self.refreshContext();
}

fn dropReasoning(self: *Agent, account: llm.Account) void {
    const previous_count = self.items.items.len;
    var retained_count: usize = 0;
    for (self.items.items) |item| {
        const drop = switch (item) {
            .reasoning => |reasoning| std.meta.activeTag(reasoning.replay) == account,
            else => false,
        };
        if (drop) {
            freeItem(self.gpa, item);
            continue;
        }
        self.items.items[retained_count] = item;
        retained_count += 1;
    }
    self.items.shrinkRetainingCapacity(retained_count);
    if (retained_count != previous_count) {
        self.measured_context = null;
        self.refreshContext();
    }
}

pub fn setEffort(self: *Agent, effort: llm.Effort) void {
    if (self.model) |model| {
        const rendered_before = model.reasoning(self.effort);
        const rendered_after = model.reasoning(effort);
        if (!rendered_before.eql(rendered_after)) self.stats.cache_usage = .{};
    }
    self.effort = effort;
    self.refreshContext();
}

fn refreshContext(self: *Agent) void {
    self.stats.context_tokens = self.contextShown();
}

fn contextShown(self: *const Agent) ?u64 {
    if (self.items.items.len == 0) return 0;
    const measured = self.measured_context orelse return null;
    const model = self.model orelse return null;
    if (!measured.model.sameName(model.name())) return null;
    const client = self.client orelse return measured.tokens;
    const account = client.account();
    if (account != measured.account) return null;
    const reasoning = model.reasoning(self.effort);
    const vendor = account.provider();
    if (reasoning.replaysReasoning(vendor) == measured.reasoning.replaysReasoning(vendor))
        return measured.tokens;
    return if (self.holdsProofOf(account)) null else measured.tokens;
}

fn holdsProofOf(self: *const Agent, account: llm.Account) bool {
    for (self.items.items) |item| {
        const reasoning = switch (item) {
            .reasoning => |value| value,
            else => continue,
        };
        if (std.meta.activeTag(reasoning.replay) == account) return true;
    }
    return false;
}

pub fn run(self: *Agent, user_text: []const u8, handler: anytype) Outcome {
    const base = self.items.items.len;
    if (self.client == null) return .{
        .receipt = .{
            .history_base = base,
            .history_end = base,
            .steering_committed_count = 0,
        },
        .disposition = .{ .failed = error.SignedOut },
    };
    var fetch: ClientFetch = .{ .client = &self.client.? };
    return self.runTurn(&fetch, user_text, handler);
}

fn runWith(self: *Agent, fetch: anytype, user_text: []const u8, handler: anytype) !void {
    return dispositionError(self.runTurn(fetch, user_text, handler).disposition);
}

fn dispositionError(disposition: Outcome.Disposition) !void {
    return switch (disposition) {
        .completed => {},
        .canceled => error.Canceled,
        .closed => error.Closed,
        .credential_replaced => error.CredentialReplaced,
        .credential_rejected => error.TokenGrantRejected,
        .failed => |err| err,
    };
}

fn runTurn(self: *Agent, fetch: anytype, user_text: []const u8, handler: anytype) Outcome {
    return self.runTurnWith(fetch, tool, user_text, handler);
}

fn runTurnWith(
    self: *Agent,
    fetch: anytype,
    comptime Dispatch: type,
    user_text: []const u8,
    handler: anytype,
) Outcome {
    self.stats.forgetTurnEvidence();
    var turn: TurnState = .{ .base = self.items.items.len, .checkpoint = self.items.items.len };
    const disposition: Outcome.Disposition =
        if (self.runRounds(Dispatch, fetch, &turn, user_text, handler)) |_|
            .completed
        else |err|
            classifyDisposition(&turn, err);
    switch (disposition) {
        .completed => {},
        else => self.rollbackTurn(&turn),
    }
    return .{
        .receipt = .{
            .history_base = turn.base,
            .history_end = self.items.items.len,
            .steering_committed_count = turn.steering_committed_count,
            .truncated = turn.truncated,
        },
        .disposition = disposition,
    };
}

fn classifyDisposition(turn: *const TurnState, err: anyerror) Outcome.Disposition {
    if (turn.presentation_closed) return .closed;
    return switch (err) {
        error.Canceled => .canceled,
        error.CredentialReplaced => .credential_replaced,
        error.TokenGrantRejected => .credential_rejected,
        else => .{ .failed = err },
    };
}

fn presentation(closed: *bool, result: anyerror!void) !void {
    result catch |err| {
        if (err == error.Closed) closed.* = true;
        return err;
    };
}

fn runRounds(
    self: *Agent,
    comptime Dispatch: type,
    fetch: anytype,
    turn: *TurnState,
    user_text: []const u8,
    handler: anytype,
) !void {
    try self.appendUser(user_text);
    var round: usize = 0;
    while (round < self.rounds_max) : (round += 1) {
        const reply = try self.fetchReply(fetch, turn, handler);
        const ran_tools = try self.runToolsWith(Dispatch, reply, turn, handler);
        if (!ran_tools) try self.commitRound(turn, handler);
        try self.refreshQuota(fetch, turn, handler);
        try self.refreshCredits(fetch, turn, handler);
        const loaded = try self.drainSkills(turn, handler);
        if (!ran_tools and !loaded) return;
        try self.drainSteering(turn, handler);
    }
    return error.TooManyToolRounds;
}

fn rollbackTurn(self: *Agent, turn: *TurnState) void {
    self.rollback(turn.checkpoint);
    if (turn.pending_steering) |steering| {
        var batch = steering;
        self.steering.restoreTaken(&batch);
        turn.pending_steering = null;
    }
}

fn commitRound(self: *Agent, turn: *TurnState, handler: anytype) !void {
    const measured = self.advanceCheckpoint(turn);
    notifyCheckpoint(handler);
    if (measured) try presentation(&turn.presentation_closed, handler.onUsage(self.stats));
}

fn advanceCheckpoint(self: *Agent, turn: *TurnState) bool {
    turn.checkpoint = self.items.items.len;
    const measured = turn.pending_context != null;
    if (turn.pending_context) |measured_context| {
        self.measured_context = measured_context;
        turn.pending_context = null;
        self.refreshContext();
    }
    if (turn.pending_steering) |batch| {
        turn.steering_committed_count += batch.len;
        freeSteeringBatch(self.gpa, batch);
        turn.pending_steering = null;
    }
    return measured;
}

fn notifyCheckpoint(handler: anytype) void {
    if (comptime @hasDecl(@TypeOf(handler.*), "onCheckpoint")) handler.onCheckpoint();
}

fn freeSteeringBatch(gpa: std.mem.Allocator, batch: [][]u8) void {
    for (batch) |message| gpa.free(message);
    gpa.free(batch);
}

fn drainSkills(self: *Agent, turn: *TurnState, handler: anytype) !bool {
    const guard = self.skill_guard orelse return false;
    var delivered = false;
    for (0..tool.SkillGuard.rules_max) |_| {
        const delivery = (try guard.takeQueued(self.gpa, self.io, self.items.items)) orelse break;
        defer self.gpa.free(delivery.text);
        try self.appendUser(delivery.text);
        try presentation(
            &turn.presentation_closed,
            notifySkill(handler, delivery.skill, delivery.source),
        );
        delivered = true;
    }
    return delivered;
}

fn notifySkill(handler: anytype, skill: []const u8, source: []const u8) !void {
    if (comptime @hasDecl(@TypeOf(handler.*), "onSkillLoaded"))
        try handler.onSkillLoaded(skill, source);
}

fn drainSteering(self: *Agent, turn: *TurnState, handler: anytype) !void {
    var pending = try self.steering.take();
    if (pending.len == 0) {
        self.gpa.free(pending);
        return;
    }
    errdefer if (turn.pending_steering == null) self.steering.restoreTaken(&pending);
    const combined = try Steering.join(self.gpa, pending);
    defer self.gpa.free(combined);
    try self.appendUser(combined);
    try presentation(&turn.presentation_closed, handler.onSteering(combined, pending.len));
    std.debug.assert(turn.pending_steering == null);
    turn.pending_steering = pending;
}

fn fetchReply(
    self: *Agent,
    fetch: anytype,
    turn: *TurnState,
    handler: anytype,
) ![]const llm.Item {
    const model = self.model orelse return error.NoModel;
    const request: llm.Request = .{
        .model = model.name(),
        .tokens_max = model.tokens_max orelse Model.tokens_max_fallback,
        .system = self.system,
        .items = self.items.items,
        .tools = &tool.specs,
        .reasoning = model.reasoning(self.effort),
        .cache_key = &self.cache_key,
    };
    var attempt: u32 = 1;
    var renewed = false;
    while (true) : (attempt += 1) {
        var stream: @TypeOf(fetch.*).Stream = undefined;
        fetch.send(&stream, &request) catch |err| {
            const failure: net.Retry.Failure = .{ .attempt = attempt };
            if (retryableError(err) and self.retry.allows(failure)) {
                try self.backoff(failure);
                try notifyRetry(turn, attempt + 1, &.{ .failure = err }, handler);
                continue;
            }
            return err;
        };
        defer stream.deinit();
        const maybe_head = stream.quotaSoFar();
        if (maybe_head) |quota| try self.adoptQuota(quota, turn, handler);

        if (!stream.ok()) {
            if (!renewed and stream.unauthorized()) {
                renewed = true;
                if (try fetch.renewCredential()) {
                    try notifyRetry(
                        turn,
                        attempt + 1,
                        &.{ .response = stream.errorText() },
                        handler,
                    );
                    continue;
                }
            }
            const failure: net.Retry.Failure = .{
                .attempt = attempt,
                .suggested_ms = stream.retryAfterMs() orelse 0,
            };
            if (stream.retryable() and self.retry.allows(failure)) {
                try self.backoff(failure);
                try notifyRetry(
                    turn,
                    attempt + 1,
                    &.{ .response = stream.errorText() },
                    handler,
                );
                continue;
            }
            try presentation(&turn.presentation_closed, handler.onError(stream.errorText()));
            return error.ApiError;
        }
        var usage_recorded = false;
        const reply = self.readReplyWith(
            &model,
            &stream,
            turn,
            &usage_recorded,
            handler,
        ) catch |err| switch (err) {
            error.ApiError => {
                self.recordUsageSoFar(&model, &stream, &usage_recorded);
                const failure: net.Retry.Failure = .{
                    .attempt = attempt,
                    .suggested_ms = stream.retryAfterMs() orelse 0,
                };
                if (stream.retryable() and self.retry.allows(failure)) {
                    try self.backoff(failure);
                    try notifyRetry(
                        turn,
                        attempt + 1,
                        &.{ .response = stream.errorText() },
                        handler,
                    );
                    continue;
                }
                try presentation(&turn.presentation_closed, handler.onError(stream.errorText()));
                return error.ApiError;
            },
            error.Canceled => {
                self.recordUsageSoFar(&model, &stream, &usage_recorded);
                return err;
            },
            else => {
                self.recordUsageSoFar(&model, &stream, &usage_recorded);
                const failure: net.Retry.Failure = .{ .attempt = attempt };
                if (retryableError(err) and self.retry.allows(failure)) {
                    try self.backoff(failure);
                    try notifyRetry(turn, attempt + 1, &.{ .failure = err }, handler);
                    continue;
                }
                return err;
            },
        };
        return reply;
    }
}

fn refreshQuota(self: *Agent, fetch: anytype, turn: *TurnState, handler: anytype) !void {
    const maybe_quota = fetch.fetchQuota() catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return,
    };
    if (maybe_quota) |quota| try self.adoptQuota(quota, turn, handler);
}

fn adoptQuota(self: *Agent, quota: llm.Quota, turn: *TurnState, handler: anytype) !void {
    self.stats.quota = quota;
    self.stats.quota_seen_ms = std.Io.Timestamp.now(self.io, .boot).toMilliseconds();
    try presentation(&turn.presentation_closed, handler.onUsage(self.stats));
}

fn refreshCredits(self: *Agent, fetch: anytype, turn: *TurnState, handler: anytype) !void {
    const maybe_credits = fetch.fetchCredits() catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return,
    };
    if (maybe_credits) |credits| try self.adoptCredits(credits, turn, handler);
}

fn adoptCredits(self: *Agent, credits: llm.Credits, turn: *TurnState, handler: anytype) !void {
    self.stats.credits = credits;
    try presentation(&turn.presentation_closed, handler.onUsage(self.stats));
}

fn notifyRetry(
    turn: *TurnState,
    attempt: u32,
    cause: *const RetryAttempt.Cause,
    handler: anytype,
) !void {
    const retry: RetryAttempt = .{ .attempt = attempt, .cause = cause.* };
    try presentation(&turn.presentation_closed, handler.onStreamReset(&retry));
}

fn backoff(self: *Agent, failure: net.Retry.Failure) !void {
    const delay_ms = self.retry.backoffMs(failure);
    const bounded: u64 = @min(delay_ms, std.math.maxInt(i64));
    try self.io.sleep(.fromMilliseconds(@intCast(bounded)), .awake);
}

fn retryableError(err: anyerror) bool {
    return switch (err) {
        error.Timeout,
        error.IncompleteReply,
        error.EmptyReply,
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

fn generateCacheKey(io: std.Io) [32]u8 {
    var seed: [16]u8 = undefined;
    io.random(&seed);
    return std.fmt.bytesToHex(seed, .lower);
}

fn rollback(self: *Agent, base: usize) void {
    for (self.items.items[base..]) |item| freeItem(self.gpa, item);
    self.items.shrinkRetainingCapacity(base);
    if (self.skill_guard) |guard| guard.forget();
    self.refreshContext();
}

fn freeItem(gpa: std.mem.Allocator, item: llm.Item) void {
    switch (item) {
        .message => |message| gpa.free(message.text),
        .reasoning => |reasoning| reasoning.replay.deinit(gpa),
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
    self.refreshContext();
}

fn contextTokens(usage: *const llm.Usage) u64 {
    return usage.input +| usage.cache_read +| usage.cache_write +| usage.output;
}

fn recordUsage(self: *Agent, model: *const Model, usage: *const llm.Usage) void {
    self.recordCharge(model, usage, null);
}

fn recordStop(self: *Agent, model: *const Model, stop: *const llm.Event.Stop) void {
    self.recordCharge(model, &stop.usage, stop.cost);
}

fn recordCharge(
    self: *Agent,
    model: *const Model,
    usage: *const llm.Usage,
    reported_cost: ?f64,
) void {
    if (reported_cost orelse model.cost(usage)) |cost| {
        self.stats.cost = @min(self.stats.cost + cost, llm.amount_usd_max);
    }
    self.stats.cache_usage = usage.*;
}

fn pricingModel(requested: *const Model, served_name: []const u8) Model {
    if (served_name.len == 0 or requested.serves(served_name)) return requested.*;
    return Model.init(served_name) catch {
        var unpriced = requested.*;
        unpriced.price = null;
        return unpriced;
    };
}

fn recordUsageSoFar(
    self: *Agent,
    model: *const Model,
    stream: anytype,
    usage_recorded: *bool,
) void {
    if (usage_recorded.*) return;
    const usage = stream.usageSoFar();
    if (std.meta.eql(usage, llm.Usage{})) return;
    self.recordUsage(model, &usage);
    usage_recorded.* = true;
}

fn readReply(
    self: *Agent,
    model: *const Model,
    stream: anytype,
    handler: anytype,
) ![]const llm.Item {
    var turn: TurnState = .{ .base = self.items.items.len, .checkpoint = self.items.items.len };
    var usage_recorded = false;
    return self.readReplyWith(model, stream, &turn, &usage_recorded, handler);
}

fn readReplyWith(
    self: *Agent,
    model: *const Model,
    stream: anytype,
    turn: *TurnState,
    usage_recorded: *bool,
    handler: anytype,
) ![]const llm.Item {
    const gpa = self.gpa;
    const presentation_closed = &turn.presentation_closed;
    const account = self.client.?.account();
    var reply_items: std.ArrayList(llm.Item) = .empty;
    defer reply_items.deinit(gpa);
    errdefer for (reply_items.items) |item| freeItem(gpa, item);
    var reply_invalid = false;
    var maybe_stop: ?llm.Event.Stop = null;
    var tool_call_count: usize = 0;

    while (try stream.next()) |event| {
        if (event == .stop) {
            maybe_stop = event.stop;
            break;
        }
        if (event == .item and event.item == .tool_call) {
            if (tool_call_count == tool_calls_max) return error.TooManyToolCalls;
            tool_call_count += 1;
        }
        if (reply_invalid) continue;
        self.appendReplyEvent(
            &reply_items,
            account,
            &event,
            presentation_closed,
            handler,
        ) catch |err| switch (err) {
            error.IncompleteReply => reply_invalid = true,
            else => return err,
        };
    }
    const stop = maybe_stop orelse return error.IncompleteReply;
    const priced_model = pricingModel(model, stop.model);
    self.recordStop(&priced_model, &stop);
    usage_recorded.* = true;
    try presentation(presentation_closed, handler.onUsage(self.stats));

    if (stop.rejection) |rejection| return switch (rejection) {
        .invalid => error.IncompleteReply,
        .unsupported => error.UnsupportedReply,
        .uncorrelated => error.UncorrelatedReply,
    };
    if (reply_invalid) return error.IncompleteReply;
    if (stop.status == .truncated and replyHasToolCall(reply_items.items))
        return error.IncompleteReply;
    if (reply_items.items.len == 0) return error.EmptyReply;
    if (stop.model.len != 0 and !model.serves(stop.model))
        try presentation(presentation_closed, handler.onModelMismatch(.{
            .requested = model.name(),
            .served = stop.model,
        }));

    const start = self.items.items.len;
    try self.items.appendSlice(gpa, reply_items.items);
    if (self.client) |client| turn.pending_context = .{
        .tokens = contextTokens(&stop.usage),
        .model = model.*,
        .account = client.account(),
        .reasoning = model.reasoning(self.effort),
    };
    if (stop.status == .truncated) turn.truncated = true;
    return self.items.items[start..];
}

fn appendReplyEvent(
    self: *Agent,
    reply_items: *std.ArrayList(llm.Item),
    account: llm.Account,
    event: *const llm.Event,
    presentation_closed: *bool,
    handler: anytype,
) !void {
    switch (event.*) {
        .text => |delta| try presentation(presentation_closed, handler.onText(delta)),
        .thinking => |delta| try presentation(presentation_closed, handler.onThinking(delta)),
        .tool_name => |name| try presentation(presentation_closed, handler.onToolName(name)),
        .tool_arguments => |delta| try presentation(
            presentation_closed,
            handler.onToolArguments(delta),
        ),
        .item => |*output| {
            const item = try dupeOutput(self.gpa, account, output, reply_items.items);
            errdefer freeItem(self.gpa, item);
            if (output.* == .reasoning and output.reasoning.isRedacted())
                try presentation(presentation_closed, handler.onThinking(redacted_notice));
            try reply_items.append(self.gpa, item);
        },
        .stop => unreachable,
    }
}

fn Runner(comptime Dispatch: type) type {
    return struct {
        fn run(call: *Call, context: *const tool.Context) void {
            call.result = .{ .finished = Dispatch.run(context, call.name, call.input_json) };
        }
    };
}

fn runTools(self: *Agent, reply: []const llm.Item, turn: *TurnState, handler: anytype) !bool {
    return self.runToolsWith(tool, reply, turn, handler);
}

fn runToolsWith(
    self: *Agent,
    comptime Dispatch: type,
    reply: []const llm.Item,
    turn: *TurnState,
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
    const calls = call_list.items;
    if (calls.len == 0) return false;
    const history_end = self.items.items.len -| reply.len;

    try self.reserveResults(calls);
    try self.commitRound(turn, handler);

    const context: tool.Context = .{
        .gpa = self.gpa,
        .io = self.io,
        .environ = self.environ,
        .bash = self.bash,
        .document = self.document,
        .skill_guard = self.skill_guard,
        .history = self.items.items[0..history_end],
    };
    var group: std.Io.Group = .init;
    errdefer {
        group.cancel(self.io);
        self.harvestResults(calls);
    }

    var reads_launched: usize = 0;
    for (calls) |*call| {
        const mutates = Dispatch.mutates(call.name);
        if (mutates or reads_launched == read_only_calls_max) {
            try group.await(self.io);
            group = .init;
            reads_launched = 0;
            try self.presentReady(calls, turn, handler);
        }
        try presentation(
            &turn.presentation_closed,
            handler.onToolStart(call.name, call.input_json),
        );
        if (mutates) {
            call.result = .{ .finished = Dispatch.run(&context, call.name, call.input_json) };
            try self.presentResult(call, turn, handler);
        } else {
            try group.concurrent(self.io, Runner(Dispatch).run, .{ call, &context });
            reads_launched += 1;
        }
    }
    try group.await(self.io);
    try self.presentReady(calls, turn, handler);
    return true;
}

fn reserveResults(self: *Agent, calls: []Call) !void {
    try self.items.ensureUnusedCapacity(self.gpa, calls.len);
    const base = self.items.items.len;
    for (calls, 0..) |*call, index| {
        const id_copy = try self.gpa.dupe(u8, call.id);
        errdefer self.gpa.free(id_copy);
        const content_copy = try self.gpa.dupe(u8, unfinished_tool_result);
        errdefer self.gpa.free(content_copy);
        self.items.appendAssumeCapacity(.{ .tool_result = .{
            .call_id = id_copy,
            .content = content_copy,
            .is_error = true,
        } });
        call.result_index = base + index;
    }
}

fn presentReady(
    self: *Agent,
    calls: []Call,
    turn: *TurnState,
    handler: anytype,
) !void {
    for (calls) |*call| {
        if (call.moved) continue;
        switch (call.result) {
            .pending => break,
            .finished => try self.presentResult(call, turn, handler),
        }
    }
}

fn presentResult(self: *Agent, call: *Call, turn: *TurnState, handler: anytype) !void {
    var result = try call.takeFinished();
    defer result.deinit(self.gpa);
    self.transferResult(call, &result);
    const slot = self.items.items[call.result_index].tool_result;
    try presentation(
        &turn.presentation_closed,
        handler.onToolResult(call.name, slot.content, result.summary, slot.is_error),
    );
}

fn harvestResults(self: *Agent, calls: []Call) void {
    for (calls) |*call| {
        if (call.moved) continue;
        if (call.result == .pending) continue;
        var result = call.takeFinished() catch continue;
        defer result.deinit(self.gpa);
        self.transferResult(call, &result);
    }
}

fn transferResult(self: *Agent, call: *Call, result: *tool.Result) void {
    const slot = &self.items.items[call.result_index].tool_result;
    self.gpa.free(slot.content);
    slot.content = result.takeContent();
    slot.is_error = result.is_error;
    call.moved = true;
}

fn replyHasToolCall(items: []const llm.Item) bool {
    for (items) |item| if (item == .tool_call) return true;
    return false;
}

fn duplicateCallId(items: []const llm.Item, id: []const u8) bool {
    for (items) |item| switch (item) {
        .tool_call => |call| if (std.mem.eql(u8, call.call_id, id)) return true,
        else => {},
    };
    return false;
}

test "only presentation callback closure maps to a closed disposition" {
    var presentation_turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expectError(
        error.Closed,
        presentation(&presentation_turn.presentation_closed, error.Closed),
    );
    try std.testing.expect(std.meta.activeTag(
        classifyDisposition(&presentation_turn, error.Closed),
    ) == .closed);

    var tool_turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    switch (classifyDisposition(&tool_turn, error.Closed)) {
        .failed => |err| try std.testing.expect(err == error.Closed),
        else => return error.UnexpectedDisposition,
    }
    switch (classifyDisposition(&tool_turn, error.PresentationChannelClosed)) {
        .failed => |err| try std.testing.expect(err == error.PresentationChannelClosed),
        else => return error.UnexpectedDisposition,
    }
}

test retryableError {
    try std.testing.expect(retryableError(error.Timeout));
    try std.testing.expect(retryableError(error.IncompleteReply));
    try std.testing.expect(retryableError(error.ConnectionResetByPeer));
    try std.testing.expect(!retryableError(error.Canceled));
    try std.testing.expect(!retryableError(error.Closed));
    try std.testing.expect(!retryableError(error.OutOfMemory));
    try std.testing.expect(!retryableError(error.StreamResponseTooLarge));
    try std.testing.expect(!retryableError(error.UncorrelatedReply));
    try std.testing.expect(!retryableError(error.UnknownServedModel));
}

test "resetConversation clears conversation state and preserves configuration" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const account = agent.client.?.account();
    const model = agent.model.?;
    const cache_key = agent.cache_key;
    agent.effort = .high;
    try agent.appendUser("old prompt");
    const usage: llm.Usage = .{ .input = 1000, .output = 200, .cache_write = 500 };
    agent.recordUsage(&agent.model.?, &usage);
    seedContext(&agent, contextTokens(&usage));
    try agent.steering.push("old steering");

    agent.resetConversation();

    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    try std.testing.expect(std.meta.eql(Stats{}, agent.stats));
    const steering = try agent.steering.take();
    defer gpa.free(steering);
    try std.testing.expectEqual(@as(usize, 0), steering.len);
    try std.testing.expect(!std.mem.eql(u8, &cache_key, &agent.cache_key));
    try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
    try std.testing.expect(agent.measured_context == null);
    try std.testing.expectEqual(account, agent.client.?.account());
    try std.testing.expectEqualStrings(model.name(), agent.model.?.name());
    try std.testing.expectEqual(llm.Effort.high, agent.effort);
}

test "an account change or sign-out clears the previous account's quota and pool" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const same_account = agent.client.?;
    var sonnet = testing.model("claude-sonnet-4-6");
    sonnet.efforts.remove(.xhigh);
    agent.stats.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };
    agent.stats.credits = .{ .total = 10, .used = 2 };

    agent.switchTo(same_account, sonnet);
    try std.testing.expect(agent.stats.quota != null);
    try std.testing.expect(agent.stats.credits != null);

    const openai_client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .openai_api_key = "sk-test" },
        .{},
    );
    const openai_model = testing.model("gpt-5.6-sol");
    agent.switchTo(openai_client, openai_model);
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expect(agent.stats.credits == null);

    agent.stats.quota = .{ .secondary = .{ .used_percent = 75, .window_minutes = 10080 } };
    agent.stats.credits = .{ .total = 10, .used = 2 };
    agent.signOut();
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expect(agent.stats.credits == null);
}

test "the cache rate expires with the principal, the model, and the wire effort" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const same_account = agent.client.?;
    var sonnet = testing.model("claude-sonnet-4-6");
    sonnet.efforts.remove(.xhigh);
    const usage: llm.Usage = .{ .input = 100, .output = 20, .cache_read = 900 };
    try agent.appendUser("committed context");

    agent.stats.cache_usage = usage;
    agent.setEffort(.high);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    agent.switchTo(same_account, sonnet);
    agent.setEffort(.high);
    agent.stats.cache_usage = usage;
    agent.setEffort(.xhigh);
    try std.testing.expectEqual(usage, agent.stats.cache_usage);

    const other_account = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_api_key = "key" },
        .{},
    );
    agent.switchTo(other_account, agent.model.?);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    agent.stats.cache_usage = usage;
    agent.switchTo(other_account, testing.model("claude-opus-4-8"));
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    agent.stats.cache_usage = usage;
    var narrowed = testing.model("claude-opus-4-8");
    narrowed.efforts.remove(.max);
    agent.switchTo(other_account, narrowed);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    agent.stats.cache_usage = usage;
    agent.signOut();
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);
}

test "the context gauge holds while the tokenizer and the replayed reasoning hold" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const subscription = agent.client.?;
    const opus = agent.model.?;
    try agent.appendUser("committed context");
    try appendProof(&agent, .anthropic_plan);
    agent.setEffort(.high);
    seedContext(&agent, 1020);

    agent.setEffort(.max);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    var closed = opus;
    closed.efforts_denied = true;
    agent.switchTo(subscription, closed);
    try std.testing.expect(agent.stats.context_tokens == null);

    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    const console = provider.Client.init(gpa, std.testing.io, .{ .anthropic_api = "k" }, .{});
    agent.switchTo(console, opus);
    try std.testing.expect(agent.stats.context_tokens == null);
    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    agent.signOut();
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);
    agent.switchTo(console, opus);
    try std.testing.expect(agent.stats.context_tokens == null);

    agent.signOut();
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);
    agent.switchTo(subscription, opus);

    agent.switchTo(subscription, testing.model("claude-sonnet-4-6"));
    try std.testing.expect(agent.stats.context_tokens == null);
    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    agent.resetConversation();
    try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
}

test "an account switch hides the count, and a switch back restores it" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const subscription = agent.client.?;
    const opus = agent.model.?;
    try agent.appendUser("committed context");
    agent.setEffort(.high);
    seedContext(&agent, 1020);

    const console = provider.Client.init(gpa, std.testing.io, .{ .anthropic_api = "k" }, .{});
    agent.switchTo(console, opus);
    try std.testing.expect(agent.stats.context_tokens == null);

    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);
}

test "the context gauge survives every effort change that replays the same reasoning" {
    const gpa = std.testing.allocator;
    var anthropic_agent = scriptedAgent(gpa);
    defer anthropic_agent.deinit();

    const subscription = anthropic_agent.client.?;
    try anthropic_agent.appendUser("committed context");
    anthropic_agent.setEffort(.high);
    seedContext(&anthropic_agent, 1020);

    var closed = anthropic_agent.model.?;
    closed.efforts_denied = true;
    anthropic_agent.switchTo(subscription, closed);
    try std.testing.expectEqual(@as(?u64, 1020), anthropic_agent.stats.context_tokens);

    const sonnet = testing.model("claude-sonnet-4-6");
    anthropic_agent.switchTo(subscription, sonnet);
    try appendProof(&anthropic_agent, .anthropic_plan);
    anthropic_agent.setEffort(.high);
    seedContext(&anthropic_agent, 1020);
    anthropic_agent.setEffort(.xhigh);
    try std.testing.expectEqual(@as(?u64, 1020), anthropic_agent.stats.context_tokens);

    var openai_agent = openaiScriptedAgent(gpa);
    defer openai_agent.deinit();
    try openai_agent.appendUser("committed context");
    try appendProof(&openai_agent, .openai_api_key);
    openai_agent.setEffort(.high);
    seedContext(&openai_agent, 1020);

    openai_agent.setEffort(.low);
    try std.testing.expectEqual(@as(?u64, 1020), openai_agent.stats.context_tokens);
}

test "usage is priced with the model that produced it, not the active one" {
    const gpa = std.testing.allocator;
    const sonnet = testing.model("claude-sonnet-4-6");
    var opus = testing.model("claude-opus-4-8");
    opus.price.?.input = 5;
    const client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_plan = undefined },
        .{},
    );
    var agent = Agent.init(gpa, std.testing.io, client, .{
        .model = sonnet,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer agent.deinit();

    const one_million: llm.Usage = .{ .input = 1_000_000 };

    agent.switchTo(client, opus);
    agent.recordUsage(&sonnet, &one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);

    agent.recordUsage(&opus, &one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 8), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 1_000_000), agent.stats.cache_usage.input);
}

test "a reported charge outranks the rate estimate" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    const model = agent.model.?;
    const usage: llm.Usage = .{ .input = 1_000_000 };
    const estimate = model.cost(&usage).?;

    agent.recordStop(&model, &.{ .usage = usage, .cost = 0.42 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), agent.stats.cost, 1e-9);

    agent.recordStop(&model, &.{ .usage = usage });
    try std.testing.expectApproxEqAbs(0.42 + estimate, agent.stats.cost, 1e-9);
}

test "the session total stops at the money bound" {
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    const model = agent.model.?;

    agent.stats.cost = llm.amount_usd_max - 1;
    agent.recordStop(&model, &.{ .usage = .{ .input = 1 }, .cost = 5 });
    try std.testing.expectEqual(llm.amount_usd_max, agent.stats.cost);

    agent.stats.cost = 0;
    const priced = testing.model("priced");
    agent.recordUsage(&priced, &.{ .input = std.math.maxInt(u64) });
    try std.testing.expectEqual(llm.amount_usd_max, agent.stats.cost);
}

test "an unpriced model adds no cost to the session total" {
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();

    const priced = testing.model("priced");
    agent.recordUsage(&priced, &.{ .input = 1_000_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);

    const unpriced = testing.bareModel("unpriced");
    agent.recordUsage(&unpriced, &.{ .input = 2_000_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 2_000_000), agent.stats.cache_usage.input);
}

const ScriptedStream = struct {
    events: []const llm.Event,
    index: usize = 0,
    maybe_events_read: ?*usize = null,
    terminal_error: ?anyerror = null,
    usage_so_far: llm.Usage = .{},
    quota: ?llm.Quota = null,
    head_ok: bool = true,
    head_retryable: bool = false,
    head_unauthorized: bool = false,
    stream_error_retryable: bool = false,
    retry_after_ms: ?u64 = null,
    error_text: []const u8 = "",

    fn next(self: *ScriptedStream) !?llm.Event {
        if (self.index == self.events.len) {
            if (self.terminal_error) |terminal_error| return terminal_error;
            return null;
        }
        defer {
            self.index += 1;
            if (self.maybe_events_read) |events_read| events_read.* = self.index;
        }
        return self.events[self.index];
    }

    fn deinit(self: *ScriptedStream) void {
        _ = self;
    }

    fn ok(self: *const ScriptedStream) bool {
        return self.head_ok;
    }

    fn retryable(self: *const ScriptedStream) bool {
        return if (self.head_ok) self.stream_error_retryable else self.head_retryable;
    }

    fn unauthorized(self: *const ScriptedStream) bool {
        return self.head_unauthorized;
    }

    fn retryAfterMs(self: *const ScriptedStream) ?u64 {
        return self.retry_after_ms;
    }

    fn errorText(self: *const ScriptedStream) []const u8 {
        return self.error_text;
    }

    fn usageSoFar(self: *const ScriptedStream) llm.Usage {
        return self.usage_so_far;
    }

    fn quotaSoFar(self: *const ScriptedStream) ?llm.Quota {
        return self.quota;
    }
};

const ScriptedFetch = struct {
    attempts: []const Attempt,
    sends: usize = 0,
    renewals: usize = 0,
    renewal_changes: bool = false,
    renewal_error: ?anyerror = null,
    quota_to_fetch: ?llm.Quota = null,
    quota_fetches: usize = 0,
    quota_error: ?anyerror = null,
    credits_to_fetch: ?llm.Credits = null,
    credits_fetches: usize = 0,
    credits_error: ?anyerror = null,

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

    fn renewCredential(self: *ScriptedFetch) !bool {
        self.renewals += 1;
        if (self.renewal_error) |err| return err;
        return self.renewal_changes;
    }

    fn fetchQuota(self: *ScriptedFetch) !?llm.Quota {
        self.quota_fetches += 1;
        if (self.quota_error) |err| return err;
        return self.quota_to_fetch;
    }

    fn fetchCredits(self: *ScriptedFetch) !?llm.Credits {
        self.credits_fetches += 1;
        if (self.credits_error) |err| return err;
        return self.credits_to_fetch;
    }
};

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

    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    defer if (turn.pending_steering) |batch| freeSteeringBatch(gpa, batch);
    try agent.steering.push("a");
    try agent.steering.push("b");
    try agent.drainSteering(&turn, &handler);

    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[0].message.role);
    try std.testing.expectEqualStrings("a\n\nb", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("a\n\nb", handler.text.items);
    try std.testing.expectEqual(@as(usize, 2), handler.count);
    try std.testing.expect(turn.pending_steering != null);
    try std.testing.expectEqual(@as(usize, 0), turn.steering_committed_count);

    try agent.drainSteering(&turn, &handler);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), handler.count);
}

test "steering appends a separate user item, leaving grouping to the serializer" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: SteerHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    defer if (turn.pending_steering) |batch| freeSteeringBatch(gpa, batch);
    try agent.appendUser("tool results");
    try agent.steering.push("steer");
    try agent.drainSteering(&turn, &handler);

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

    const CancelHandler = struct {
        fn onSteering(self: *@This(), text: []const u8, count: usize) !void {
            _ = self;
            _ = text;
            _ = count;
            return error.Canceled;
        }
    };
    var handler: CancelHandler = .{};

    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try agent.steering.push("a");
    try agent.steering.push("b");
    try std.testing.expectError(error.Canceled, agent.drainSteering(&turn, &handler));
    try std.testing.expect(turn.pending_steering == null);

    const taken = try agent.steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 2), taken.len);
    try std.testing.expectEqualStrings("a", taken[0]);
    try std.testing.expectEqualStrings("b", taken[1]);
}

test "a callback failure after recall restores the batch as a queue prefix" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const RecallCancelHandler = struct {
        gpa: std.mem.Allocator,
        steering: *Steering,

        fn onSteering(self: *@This(), text: []const u8, count: usize) !void {
            _ = text;
            _ = count;
            try self.steering.push("newer");
            const recalled = try self.steering.take();
            defer {
                for (recalled) |message| self.gpa.free(message);
                self.gpa.free(recalled);
            }
            try std.testing.expectEqual(@as(usize, 1), recalled.len);
            try std.testing.expectEqualStrings("newer", recalled[0]);
            return error.Canceled;
        }
    };
    var handler: RecallCancelHandler = .{ .gpa = gpa, .steering = &agent.steering };

    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try agent.steering.push("a");
    try agent.steering.push("b");
    try std.testing.expectError(error.Canceled, agent.drainSteering(&turn, &handler));

    const restored = try agent.steering.take();
    defer {
        for (restored) |message| gpa.free(message);
        gpa.free(restored);
    }
    try std.testing.expectEqual(@as(usize, 2), restored.len);
    try std.testing.expectEqualStrings("a", restored[0]);
    try std.testing.expectEqualStrings("b", restored[1]);
}

const CaptureHandler = struct {
    gpa: std.mem.Allocator,
    thinking: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    streamed_tools: std.ArrayList(u8) = .empty,
    model_mismatches: std.ArrayList(u8) = .empty,
    retries: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    published_context: std.ArrayList(?u64) = .empty,
    usage_count: usize = 0,
    tool_start_count: usize = 0,
    tool_result_count: usize = 0,
    tool_summary_count: usize = 0,
    stream_reset_count: usize = 0,
    steer_count: usize = 0,
    checkpoint_count: usize = 0,
    fail_usage: bool = false,

    fn deinit(self: *CaptureHandler) void {
        self.thinking.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.streamed_tools.deinit(self.gpa);
        self.model_mismatches.deinit(self.gpa);
        self.retries.deinit(self.gpa);
        self.errors.deinit(self.gpa);
        self.published_context.deinit(self.gpa);
    }

    fn onStreamReset(self: *CaptureHandler, retry: *const RetryAttempt) !void {
        self.stream_reset_count += 1;
        switch (retry.cause) {
            .failure => |failure| try self.retries.print(
                self.gpa,
                "{d} failure {s}\n",
                .{ retry.attempt, @errorName(failure) },
            ),
            .response => |response| try self.retries.print(
                self.gpa,
                "{d} response {s}\n",
                .{ retry.attempt, response },
            ),
        }
    }

    fn onError(self: *CaptureHandler, text: []const u8) !void {
        try self.errors.appendSlice(self.gpa, text);
    }

    fn onSteering(self: *CaptureHandler, text: []const u8, count: usize) !void {
        _ = text;
        self.steer_count += count;
    }

    fn onCheckpoint(self: *CaptureHandler) void {
        self.checkpoint_count += 1;
    }

    fn onThinking(self: *CaptureHandler, delta: []const u8) !void {
        try self.thinking.appendSlice(self.gpa, delta);
    }

    fn onText(self: *CaptureHandler, delta: []const u8) !void {
        try self.text.appendSlice(self.gpa, delta);
    }

    fn onUsage(self: *CaptureHandler, stats: Stats) !void {
        try self.published_context.append(self.gpa, stats.context_tokens);
        self.usage_count += 1;
        if (self.fail_usage) return error.Canceled;
    }

    fn onModelMismatch(self: *CaptureHandler, mismatch: ModelMismatch) !void {
        try self.model_mismatches.print(self.gpa, "{s} {s}\n", .{
            mismatch.requested,
            mismatch.served,
        });
    }

    fn onToolName(self: *CaptureHandler, name: []const u8) !void {
        if (self.streamed_tools.items.len != 0)
            try self.streamed_tools.append(self.gpa, '\n');
        try self.streamed_tools.print(self.gpa, "{s} ", .{name});
    }

    fn onToolArguments(self: *CaptureHandler, delta: []const u8) !void {
        try self.streamed_tools.appendSlice(self.gpa, delta);
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
        maybe_summary: ?tool.Result.Summary,
        is_error: bool,
    ) !void {
        _ = name;
        _ = content;
        _ = is_error;
        self.tool_result_count += 1;
        if (maybe_summary != null) self.tool_summary_count += 1;
    }
};

fn scriptedAgent(gpa: std.mem.Allocator) Agent {
    const model = testing.model("claude-opus-4-8");
    const client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_plan = undefined },
        .{},
    );
    return Agent.init(gpa, std.testing.io, client, .{
        .model = model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
}

fn seedContext(agent: *Agent, tokens: u64) void {
    agent.measured_context = .{
        .tokens = tokens,
        .model = agent.model.?,
        .account = agent.client.?.account(),
        .reasoning = agent.model.?.reasoning(agent.effort),
    };
    agent.refreshContext();
}

fn appendProof(agent: *Agent, account: llm.Account) !void {
    const gpa = agent.gpa;
    const text = try gpa.dupe(u8, "think");
    errdefer gpa.free(text);
    const proof = try gpa.dupe(u8, "proof");
    errdefer gpa.free(proof);
    const replay: llm.Item.Reasoning.Replay = switch (account) {
        inline .anthropic_plan,
        .anthropic_api_key,
        .anthropic_api,
        => |tag| @unionInit(
            llm.Item.Reasoning.Replay,
            @tagName(tag),
            .{ .signature = .{ .text = text, .signature = proof } },
        ),
        inline .openai_plan,
        .openai_api_key,
        .xai_plan,
        .xai_api_key,
        .openrouter_api,
        .openrouter_api_key,
        .deepseek_api_key,
        .ds4,
        => |tag| replay: {
            const id = try gpa.dupe(u8, "rs_1");
            break :replay @unionInit(
                llm.Item.Reasoning.Replay,
                @tagName(tag),
                .{ .text = text, .id = id, .encrypted_content = proof },
            );
        },
        .google_cloud_key => .{
            .google_cloud_key = .{ .text = text, .signature = proof },
        },
    };
    try agent.items.append(gpa, .{ .reasoning = .{ .replay = replay } });
}

fn openaiScriptedAgent(gpa: std.mem.Allocator) Agent {
    const model = testing.model("gpt-5.6-sol");
    const client = provider.Client.init(gpa, std.testing.io, .{ .openai_api_key = "sk-test" }, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
}

fn anthropicStream(io: std.Io, reader: *std.Io.Reader, idle_ms: u64) provider.Stream {
    var stream: provider.Stream = .{ .anthropic_plan = undefined };
    stream.anthropic_plan.gpa = std.testing.allocator;
    stream.anthropic_plan.io = io;
    stream.anthropic_plan.idle_ms = idle_ms;
    stream.anthropic_plan.budget = .{ .max = net.stream_response_bytes_max };
    stream.anthropic_plan.body = reader;
    stream.anthropic_plan.frame_arena = .init(std.testing.allocator);
    stream.anthropic_plan.beginDecode();
    stream.anthropic_plan.usage = .{};
    return stream;
}

fn openaiStream(io: std.Io, reader: *std.Io.Reader) provider.Stream {
    var stream: provider.Stream = .{ .openai_api_key = undefined };
    stream.openai_api_key.gpa = std.testing.allocator;
    stream.openai_api_key.io = io;
    stream.openai_api_key.idle_ms = 60_000;
    stream.openai_api_key.budget = .{ .max = net.stream_response_bytes_max };
    stream.openai_api_key.body = reader;
    stream.openai_api_key.frame_arena = .init(std.testing.allocator);
    stream.openai_api_key.beginDecode();
    stream.openai_api_key.usage = .{};
    return stream;
}

fn expectIncompleteToolStream(
    agent: *Agent,
    stream: *provider.Stream,
    handler: *CaptureHandler,
) !void {
    const maybe_reply: ?[]const llm.Item =
        agent.readReply(&agent.model.?, stream, handler) catch |err| switch (err) {
            error.IncompleteReply => null,
            else => return err,
        };
    var turn: TurnState = .{ .base = agent.items.items.len, .checkpoint = agent.items.items.len };
    if (maybe_reply) |reply| _ = try agent.runTools(reply, &turn, handler);

    try std.testing.expect(maybe_reply == null);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "readReply stops before a post-completion timeout" {
    const events = [_]llm.Event{
        .{ .text = "done" },
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 4 } } },
    };
    var stream: ScriptedStream = .{ .events = &events, .terminal_error = error.Timeout };
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
}

test "readReply reports a reply that another model served" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const served_by_fallback = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1 }, .model = "claude-sonnet-4-6" } },
    };
    var fallback_stream: ScriptedStream = .{ .events = &served_by_fallback };
    _ = try agent.readReply(&agent.model.?, &fallback_stream, &handler);
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-sonnet-4-6\n",
        handler.model_mismatches.items,
    );

    const served_as_requested = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1 }, .model = "claude-opus-4-8" } },
    };
    var matching_stream: ScriptedStream = .{ .events = &served_as_requested };
    _ = try agent.readReply(&agent.model.?, &matching_stream, &handler);
    const served_unnamed = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1 } } },
    };
    var unnamed_stream: ScriptedStream = .{ .events = &served_unnamed };
    _ = try agent.readReply(&agent.model.?, &unnamed_stream, &handler);
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-sonnet-4-6\n",
        handler.model_mismatches.items,
    );

    const served_and_rejected = [_]llm.Event{
        .{ .text = "partial" },
        .{ .item = .{ .message = "partial" } },
        .{ .stop = .{
            .usage = .{ .output = 1 },
            .rejection = .invalid,
            .model = "claude-sonnet-4-6",
        } },
    };
    var rejected_stream: ScriptedStream = .{ .events = &served_and_rejected };
    try std.testing.expectError(
        error.IncompleteReply,
        agent.readReply(&agent.model.?, &rejected_stream, &handler),
    );
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-sonnet-4-6\n",
        handler.model_mismatches.items,
    );
}

test "readReply prices a reply that the requested model served" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const usage: llm.Usage = .{ .input = 1_000_000, .output = 10_000, .cache_write = 100 };
    const events = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = usage, .model = "claude-opus-4-8" } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model.?, &stream, &handler);

    try std.testing.expectEqual(agent.model.?.cost(&usage), agent.stats.cost);
    try std.testing.expectEqual(usage, agent.stats.cache_usage);
}

test "readReply reads the id behind an alias as the requested model" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();
    try agent.model.?.serveAs("claude-opus-4-8-20260101");

    const usage: llm.Usage = .{ .input = 1_000_000, .output = 10_000 };
    const events = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = usage, .model = "claude-opus-4-8-20260101" } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model.?, &stream, &handler);

    try std.testing.expectEqual(@as(usize, 0), handler.model_mismatches.items.len);
    try std.testing.expectEqual(agent.model.?.cost(&usage), agent.stats.cost);
}

test "readReply keeps a reply that an unknown model served, unpriced" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1 }, .model = "claude-mythos-5" } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model.?, &stream, &handler);

    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqual(@as(usize, 0), handler.errors.items.len);
    try std.testing.expectEqual(@as(f64, 0), agent.stats.cost);
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-mythos-5\n",
        handler.model_mismatches.items,
    );
}

test "readReply keeps a reply that a model with an over-long name served" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const served = "c" ** (Model.name_bytes_max + 1);
    try std.testing.expect(agent.model.?.price != null);
    try std.testing.expect(pricingModel(&agent.model.?, served).price == null);

    const events = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1_000_000 }, .model = served } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model.?, &stream, &handler);

    try std.testing.expectEqual(@as(f64, 0), agent.stats.cost);
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 " ++ served ++ "\n",
        handler.model_mismatches.items,
    );
}

test "readReply streams a tool call's name and arguments for display alone" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .tool_name = "read" },
        .{ .tool_arguments = "{\"path\":" },
        .{ .tool_arguments = "\"x\"}" },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{\"path\":\"x\"}",
        } } },
        .{ .stop = .{ .usage = .{ .output = 3 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model.?, &stream, &handler);

    try std.testing.expectEqualStrings("read {\"path\":\"x\"}", handler.streamed_tools.items);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("t1", reply[0].tool_call.call_id);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
}

test "readReply records terminal usage before rejecting an invalid reply" {
    const gpa = std.testing.allocator;
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .item = .{ .tool_call = .{
                .call_id = "t1",
                .name = "read",
                .arguments_json = "{}",
            } } },
            .{ .stop = .{ .usage = .{ .input = 17 }, .status = .truncated } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 17), agent.stats.cache_usage.input);
        try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .thinking = "unfinished" },
            .{ .stop = .{ .usage = .{ .output = 23 } } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.EmptyReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 23), agent.stats.cache_usage.output);
        try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    }
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .item = .{ .tool_call = .{
                .call_id = "t1",
                .name = "read",
                .arguments_json = "not json",
            } } },
            .{ .text = "ignored" },
            .{ .stop = .{ .usage = .{ .cache_read = 29 } } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(events.len, stream.index);
        try std.testing.expectEqual(@as(u64, 29), agent.stats.cache_usage.cache_read);
        try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
        try std.testing.expectEqualStrings("", handler.text.items);
    }
}

test "readReply rejects a terminal response with no assistant items" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();
    const events = [_]llm.Event{
        .{ .stop = .{ .usage = .{ .output = 3 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    try std.testing.expectError(
        error.EmptyReply,
        agent.readReply(&agent.model.?, &stream, &handler),
    );
    try std.testing.expectEqual(@as(u64, 3), agent.stats.cache_usage.output);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "a failed reply attempt reclaims its transient allocations" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const big = "x" ** 4096;
    const events = [_]llm.Event{
        .{ .text = big },
        .{ .item = .{ .message = big } },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{}",
        } } },
    };

    handler.text.clearRetainingCapacity();
    var warmup: ScriptedStream = .{ .events = &events, .terminal_error = error.Timeout };
    try std.testing.expectError(error.Timeout, agent.readReply(&agent.model.?, &warmup, &handler));
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    const settled = failing.allocated_bytes - failing.freed_bytes;

    const attempts = 64;
    for (0..attempts) |_| {
        handler.text.clearRetainingCapacity();
        var stream: ScriptedStream = .{ .events = &events, .terminal_error = error.Timeout };
        try std.testing.expectError(
            error.Timeout,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }

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

    const events = [_]llm.Event{
        .{ .thinking = "weigh it" },
        .{ .item = .{ .reasoning = .{
            .signature = .{ .text = "weigh it", .signature = "sig" },
        } } },
        .{ .text = "answer" },
        .{ .item = .{ .message = "answer" } },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expect(agent.items.items.len > base);

    agent.rollback(base);
    try std.testing.expectEqual(base, agent.items.items.len);
    try std.testing.expectEqualStrings("keep me", agent.items.items[base - 1].message.text);
}

test "rewindHistory removes a turn and keeps the billing evidence" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    try agent.appendUser("earlier");
    const base = agent.items.items.len;
    try agent.appendUser("fix it");
    try appendProof(&agent, .anthropic_plan);
    try agent.appendUser("and test");
    const end = agent.items.items.len;
    seedContext(&agent, 1200);
    agent.stats.cost = 0.25;
    agent.stats.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };
    const cache_key = agent.cache_key;
    try std.testing.expectEqual(@as(?u64, 1200), agent.stats.context_tokens);

    agent.rewindHistory(.{ .base = base, .end = end });
    try std.testing.expectEqual(base, agent.items.items.len);
    try std.testing.expectEqualStrings("earlier", agent.items.items[0].message.text);
    try std.testing.expect(agent.measured_context == null);
    try std.testing.expect(agent.stats.context_tokens == null);
    try std.testing.expectEqual(@as(f64, 0.25), agent.stats.cost);
    try std.testing.expect(agent.stats.quota != null);
    try std.testing.expectEqualSlices(u8, &cache_key, &agent.cache_key);

    agent.rewindHistory(.{ .base = 0, .end = base });
    try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
}

test "producedBefore counts the proofs of one account below an index" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    try appendProof(&agent, .anthropic_plan);
    try agent.appendUser("fix it");
    try appendProof(&agent, .openai_api_key);
    try appendProof(&agent, .anthropic_plan);
    try agent.appendUser("and test");

    try std.testing.expectEqual(@as(usize, 0), agent.producedBefore(.anthropic_plan, 0));
    try std.testing.expectEqual(@as(usize, 1), agent.producedBefore(.anthropic_plan, 2));
    try std.testing.expectEqual(@as(usize, 1), agent.producedBefore(.anthropic_plan, 3));
    try std.testing.expectEqual(@as(usize, 2), agent.producedBefore(.anthropic_plan, 5));
    try std.testing.expectEqual(@as(usize, 1), agent.producedBefore(.openai_api_key, 5));
    try std.testing.expectEqual(@as(usize, 0), agent.producedBefore(.xai_plan, 5));
}

fn readReplyUnderOom(allocator: std.mem.Allocator) !void {
    var agent = scriptedAgent(allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = allocator };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = "weigh it" },
        .{ .item = .{ .reasoning = .{
            .signature = .{ .text = "weigh it", .signature = "sig" },
        } } },
        .{ .item = .{ .reasoning = .{ .redacted = "enc" } } },
        .{ .text = "answer" },
        .{ .item = .{ .message = "answer" } },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{\"path\":\"a\"}",
        } } },
        .{ .text = "trailing" },
        .{ .item = .{ .message = "trailing" } },
        .{ .stop = .{ .usage = .{ .output = 5 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model.?, &stream, &handler);
}

fn readOpenAiReasoningUnderOom(allocator: std.mem.Allocator) !void {
    var agent = openaiScriptedAgent(allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = allocator };
    defer handler.deinit();
    const events = [_]llm.Event{
        .{ .thinking = "encrypted" },
        .{ .item = .{ .reasoning = .{ .encrypted = .{
            .text = "encrypted",
            .id = "rs_1",
            .encrypted_content = "ciphertext",
        } } } },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model.?, &stream, &handler);
}

test "readReply frees partial work at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readReplyUnderOom, .{});
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readOpenAiReasoningUnderOom,
        .{},
    );
}

test "readReply accepts Anthropic message_stop without waiting for later traffic" {
    const body =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\"," ++
        "\"delta\":{\"stop_reason\":\"end_turn\"}," ++
        "\"usage\":{\"output_tokens\":4}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n" ++
        "data: {\"type\":\"ping\"}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = anthropicStream(threaded.io(), &reader, 0);
    defer stream.anthropic_plan.deinitDecode();
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(u64, 10), agent.stats.cache_usage.input);
    try std.testing.expectEqual(@as(u64, 4), agent.stats.cache_usage.output);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "message_stop") == null);
    try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "ping") != null);
}

test "readReply accepts OpenAI completion without consuming its done sentinel" {
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{" ++
        "\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[" ++
        "{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n" ++
        "data: {\"type\":\"response.completed\"," ++
        "\"response\":{\"status\":\"completed\",\"usage\":" ++
        "{\"input_tokens\":10,\"output_tokens\":4}}}\n\n" ++
        "data: [DONE]\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = openaiStream(threaded.io(), &reader);
    defer stream.openai_api_key.deinitDecode();
    var agent = openaiScriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(u64, 10), agent.stats.cache_usage.input);
    try std.testing.expectEqual(@as(u64, 4), agent.stats.cache_usage.output);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "[DONE]") != null);
}

test "provider rejections retain terminal usage before failing the reply" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    {
        const body =
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11}}}\n\n" ++
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}," ++
            "\"usage\":{\"output_tokens\":7}}\n\n" ++
            "data: {\"type\":\"message_stop\"}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = anthropicStream(threaded.io(), &reader, 60_000);
        defer stream.anthropic_plan.deinitDecode();
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();

        try std.testing.expectError(
            error.UnsupportedReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 11), agent.stats.cache_usage.input);
        try std.testing.expectEqual(@as(u64, 7), agent.stats.cache_usage.output);
        try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    }
    {
        const body =
            "data: {\"type\":\"response.refusal.delta\",\"delta\":\"no\"}\n\n" ++
            "data: {\"type\":\"response.refusal.done\",\"refusal\":\"no\"}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"," ++
            "\"usage\":{\"input_tokens\":13,\"output_tokens\":5}}}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(threaded.io(), &reader);
        defer stream.openai_api_key.deinitDecode();
        var agent = openaiScriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();

        try std.testing.expectError(
            error.UnsupportedReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 13), agent.stats.cache_usage.input);
        try std.testing.expectEqual(@as(u64, 5), agent.stats.cache_usage.output);
        try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    }
    {
        const body =
            "data: {\"type\":\"response.output_item.added\",\"item\":" ++
            "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\"," ++
            "\"name\":\"read\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":" ++
            "{\"id\":\"fc_1\",\"type\":\"function_call\",\"status\":\"incomplete\"," ++
            "\"call_id\":\"call_1\",\"arguments\":\"{}\"}}\n\n" ++
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"," ++
            "\"usage\":{\"input_tokens\":17,\"output_tokens\":3}}}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(threaded.io(), &reader);
        defer stream.openai_api_key.deinitDecode();
        var agent = openaiScriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();

        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 17), agent.stats.cache_usage.input);
        try std.testing.expectEqual(@as(u64, 3), agent.stats.cache_usage.output);
        try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

fn expectUnencryptedReply(options: struct {
    item: []const u8,
    field: []const u8,
    part_type: []const u8,
}) !void {
    const gpa = std.testing.allocator;
    const openai = @import("openai/root.zig");
    inline for (.{
        llm.Account.openrouter_api,
        llm.Account.openrouter_api_key,
        llm.Account.deepseek_api_key,
    }) |account| {
        const body = try std.fmt.allocPrint(
            gpa,
            "data: {{\"type\":\"response.reasoning_text.delta\",\"delta\":\"think\"}}\n\n" ++
                "data: {{\"type\":\"response.output_item.done\",\"item\":{s}}}\n\n" ++
                "data: {{\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}}\n\n" ++
                "data: {{\"type\":\"response.output_item.done\",\"item\":{{\"type\":\"message\"," ++
                "\"id\":\"msg_1\",\"content\":[{{\"type\":\"output_text\"," ++
                "\"text\":\"answer\"}}]}}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"usage\":" ++
                "{{\"input_tokens\":7,\"output_tokens\":3,\"cost\":0.000123}}}}}}\n\n",
            .{options.item},
        );
        defer gpa.free(body);
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(std.testing.io, &reader);
        stream.openai_api_key.plain_reasoning = true;
        defer stream.openai_api_key.deinitDecode();
        var agent = openaiScriptedAgent(gpa);
        defer agent.deinit();
        agent.client.?.credentials = @unionInit(provider.Credentials, @tagName(account), "test");
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();

        const reply = try agent.readReply(&agent.model.?, &stream, &handler);
        try std.testing.expectEqual(@as(usize, 2), reply.len);
        try std.testing.expectEqual(account, std.meta.activeTag(reply[0].reasoning.replay));
        try std.testing.expectEqualStrings("answer", reply[1].message.text);
        try std.testing.expectEqualStrings("answer", handler.text.items);
        try std.testing.expectEqualStrings("think", handler.thinking.items);
        try std.testing.expectEqual(@as(f64, 0.000123), agent.stats.cost);

        const replay = try openai.wire.serialize(gpa, &.{
            .model = "qwen/qwen3.8-flash",
            .system = "",
            .tokens_max = 128,
            .items = reply,
            .tools = &.{},
        }, account);
        defer gpa.free(replay);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, replay, .{});
        defer parsed.deinit();
        const input = parsed.value.object.get("input").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), input.len);
        const reasoning = input[0].object;
        try std.testing.expect(reasoning.get("encrypted_content") == null);
        const part = reasoning.get(options.field).?.array.items[0].object;
        try std.testing.expectEqualStrings(options.part_type, part.get("type").?.string);
        try std.testing.expectEqualStrings("think", part.get("text").?.string);
    }
}

test "readReply retains and replays an OpenRouter summary without encryption" {
    try expectUnencryptedReply(.{
        .item =
        \\{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"think"}]}
        ,
        .field = "summary",
        .part_type = "summary_text",
    });
}

test "readReply retains and replays raw OpenRouter reasoning without encryption" {
    try expectUnencryptedReply(.{
        .item =
        \\{"type":"reasoning","id":"rs_1","summary":[],"content":[{"type":"reasoning_text","text":"think"}],"encrypted_content":""}
        ,
        .field = "content",
        .part_type = "reasoning_text",
    });
}

test "a zero charge after a rejected reply keeps the earlier charge" {
    const gpa = std.testing.allocator;
    var agent = openaiScriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();
    const rejected = [_]llm.Event{
        .{ .stop = .{ .usage = .{ .input = 7 }, .cost = 0.000123, .rejection = .invalid } },
    };
    var failed: ScriptedStream = .{ .events = &rejected };
    try std.testing.expectError(
        error.IncompleteReply,
        agent.readReply(&agent.model.?, &failed, &handler),
    );
    const accepted = [_]llm.Event{
        .{ .item = .{ .message = "answer" } },
        .{ .stop = .{ .usage = .{ .input = 7 }, .cost = 0 } },
    };
    var retry: ScriptedStream = .{ .events = &accepted };
    _ = try agent.readReply(&agent.model.?, &retry, &handler);
    try std.testing.expectEqual(@as(f64, 0.000123), agent.stats.cost);
    try std.testing.expectEqual(@as(usize, 2), handler.usage_count);
}

test "readReply separates OpenAI reasoning summary parts with a blank line" {
    const body =
        "data: {\"type\":\"response.reasoning_summary_part.added\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":0,\"delta\":\"a\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_part.added\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":1,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":1,\"delta\":\"b\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\"," ++
        "\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[" ++
        "{\"type\":\"summary_text\",\"text\":\"a\"},{\"type\":\"summary_text\",\"text\":\"b\"}]," ++
        "\"encrypted_content\":\"enc\"}}\n\n" ++
        "data: {\"type\":\"response.completed\"," ++
        "\"response\":{\"status\":\"completed\",\"usage\":" ++
        "{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = openaiStream(threaded.io(), &reader);
    defer stream.openai_api_key.deinitDecode();
    var agent = openaiScriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("a\n\nb", reply[0].reasoning.replay.openai_api_key.text);
    try std.testing.expectEqual(
        llm.Account.openai_api_key,
        std.meta.activeTag(reply[0].reasoning.replay),
    );
    try std.testing.expectEqualStrings(
        "enc",
        reply[0].reasoning.replay.openai_api_key.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.replay.openai_api_key.id);
    try std.testing.expectEqualStrings("a\n\nb", handler.thinking.items);
}

test "readReply separates a redacted Anthropic block from the reasoning before it" {
    const body =
        "data: {\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"thinking\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"weigh it\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1," ++
        "\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"enc\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}," ++
        "\"usage\":{\"output_tokens\":2}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = anthropicStream(threaded.io(), &reader, 60_000);
    defer stream.anthropic_plan.deinitDecode();
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings(
        "weigh it",
        reply[0].reasoning.replay.anthropic_plan.signature.text,
    );
    try std.testing.expectEqualStrings(
        "enc",
        reply[1].reasoning.replay.anthropic_plan.redacted,
    );
    try std.testing.expectEqualStrings("weigh it\n\n" ++ redacted_notice, handler.thinking.items);
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
        defer stream.anthropic_plan.deinitDecode();
        var agent = scriptedAgent(std.testing.allocator);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
        defer handler.deinit();

        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), handler.usage_count);
    }

    {
        const body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(threaded.io(), &reader);
        defer stream.openai_api_key.deinitDecode();
        var agent = openaiScriptedAgent(std.testing.allocator);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
        defer handler.deinit();

        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
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
        defer stream.anthropic_plan.deinitDecode();
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
        defer stream.openai_api_key.deinitDecode();
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
        .{ .thinking = "weigh " },
        .{ .thinking = "it" },
        .{ .item = .{ .reasoning = .{
            .signature = .{ .text = "weigh it", .signature = "sig" },
        } } },
        .{ .text = "answer" },
        .{ .item = .{ .message = "answer" } },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{\"path\":\"a\"}",
        } } },
        .{ .stop = .{ .usage = .{ .output = 5 } } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expectEqualStrings(
        "weigh it",
        reply[0].reasoning.replay.anthropic_plan.signature.text,
    );
    try std.testing.expectEqual(
        llm.Account.anthropic_plan,
        std.meta.activeTag(reply[0].reasoning.replay),
    );
    try std.testing.expectEqualStrings(
        "sig",
        reply[0].reasoning.replay.anthropic_plan.signature.signature,
    );
    try std.testing.expectEqualStrings("answer", reply[1].message.text);
    try std.testing.expectEqualStrings("t1", reply[2].tool_call.call_id);
    try std.testing.expectEqualStrings("read", reply[2].tool_call.name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", reply[2].tool_call.arguments_json);
    try std.testing.expectEqualStrings("weigh it", handler.thinking.items);
    try std.testing.expectEqual(@as(usize, 1), handler.usage_count);
    try std.testing.expectEqual(@as(u64, 5), agent.stats.cache_usage.output);
}

test "readReply keeps a redacted block and a signature-only run in order" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .item = .{ .reasoning = .{ .redacted = "enc" } } },
        .{ .item = .{ .reasoning = .{
            .signature = .{ .text = "", .signature = "sigonly" },
        } } },
        .{ .text = "hi" },
        .{ .item = .{ .message = "hi" } },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 3), reply.len);
    try std.testing.expectEqualStrings(
        "enc",
        reply[0].reasoning.replay.anthropic_plan.redacted,
    );
    try std.testing.expectEqualStrings(
        "",
        reply[1].reasoning.replay.anthropic_plan.signature.text,
    );
    try std.testing.expectEqualStrings(
        "sigonly",
        reply[1].reasoning.replay.anthropic_plan.signature.signature,
    );
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
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .text = "after" },
        .{ .item = .{ .message = "after" } },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings("t1", reply[0].tool_call.call_id);
    try std.testing.expectEqualStrings("after", reply[1].message.text);
}

test "readReply keeps adjacent reasoning runs as separate items in stream order" {
    const gpa = std.testing.allocator;
    var agent = openaiScriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = "A" },
        .{ .item = .{ .reasoning = .{ .encrypted = .{
            .text = "A",
            .id = "rs_a",
            .encrypted_content = "encA",
        } } } },
        .{ .thinking = "B" },
        .{ .item = .{ .reasoning = .{ .encrypted = .{
            .text = "B",
            .id = "rs_b",
            .encrypted_content = "encB",
        } } } },
        .{ .text = "between" },
        .{ .item = .{ .message = "between" } },
        .{ .thinking = "C" },
        .{ .item = .{ .reasoning = .{ .encrypted = .{
            .text = "C",
            .id = "rs_c",
            .encrypted_content = "encC",
        } } } },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 5), reply.len);
    try std.testing.expectEqualStrings("A", reply[0].reasoning.replay.openai_api_key.text);
    try std.testing.expectEqualStrings(
        "encA",
        reply[0].reasoning.replay.openai_api_key.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_a", reply[0].reasoning.replay.openai_api_key.id);
    try std.testing.expectEqualStrings("B", reply[1].reasoning.replay.openai_api_key.text);
    try std.testing.expectEqualStrings(
        "encB",
        reply[1].reasoning.replay.openai_api_key.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_b", reply[1].reasoning.replay.openai_api_key.id);
    try std.testing.expectEqualStrings("between", reply[2].message.text);
    try std.testing.expectEqualStrings("C", reply[3].reasoning.replay.openai_api_key.text);
    try std.testing.expectEqualStrings(
        "encC",
        reply[3].reasoning.replay.openai_api_key.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_c", reply[3].reasoning.replay.openai_api_key.id);
    try std.testing.expectEqualStrings("t1", reply[4].tool_call.call_id);
}

test "readReply binds reasoning proof to the active account" {
    const gpa = std.testing.allocator;
    var agent = openaiScriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .thinking = "hmm" },
        .{ .item = .{ .reasoning = .{ .encrypted = .{
            .text = "hmm",
            .id = "rs_1",
            .encrypted_content = "enc",
        } } } },
        .{ .text = "done" },
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{} } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqual(
        llm.Account.openai_api_key,
        std.meta.activeTag(reply[0].reasoning.replay),
    );
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.replay.openai_api_key.id);
    try std.testing.expectEqualStrings("hmm", reply[0].reasoning.replay.openai_api_key.text);
    try std.testing.expectEqualStrings(
        "enc",
        reply[0].reasoning.replay.openai_api_key.encrypted_content,
    );
    try std.testing.expectEqualStrings("done", reply[1].message.text);
}

test "dropReasoning invalidates only the replaced account slot" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const anthropic_events = [_]llm.Event{
        .{ .item = .{ .reasoning = .{
            .signature = .{ .text = "a", .signature = "sig" },
        } } },
        .{ .stop = .{ .usage = .{} } },
    };
    var anthropic_stream: ScriptedStream = .{ .events = &anthropic_events };
    _ = try agent.readReply(&agent.model.?, &anthropic_stream, &handler);

    const openai_model = testing.model("gpt-5.6-sol");
    const openai_client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .openai_api_key = "sk-test" },
        .{},
    );
    agent.switchTo(openai_client, openai_model);
    const openai_events = [_]llm.Event{
        .{ .item = .{ .reasoning = .{ .encrypted = .{
            .text = "b",
            .id = "rs_1",
            .encrypted_content = "enc",
        } } } },
        .{ .stop = .{ .usage = .{} } },
    };
    var openai_stream: ScriptedStream = .{ .events = &openai_events };
    _ = try agent.readReply(&agent.model.?, &openai_stream, &handler);

    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    seedContext(&agent, 1020);
    agent.dropReasoning(.anthropic_plan);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(
        llm.Account.openai_api_key,
        std.meta.activeTag(agent.items.items[0].reasoning.replay),
    );
    try std.testing.expect(agent.stats.context_tokens == null);
    agent.dropReasoning(.openai_api_key);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
}

test "dropped account evidence takes the allowance of the active account only" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    const quota: llm.Quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };

    const usage: llm.Usage = .{ .input = 100, .cache_read = 900 };
    agent.stats.quota = quota;
    agent.stats.cache_usage = usage;
    agent.dropAccountEvidence(.openai_api_key);
    try std.testing.expect(agent.stats.quota != null);
    try std.testing.expectEqual(usage, agent.stats.cache_usage);

    agent.dropAccountEvidence(.anthropic_plan);
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    agent.signOut();
    agent.stats.quota = quota;
    agent.dropAccountEvidence(.anthropic_plan);
    try std.testing.expect(agent.stats.quota != null);
}

test "readReply retains a truncated tool-free reply but rejects a truncated tool call" {
    const gpa = std.testing.allocator;
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .text = "half" },
            .{ .item = .{ .message = "half" } },
            .{ .stop = .{ .usage = .{}, .status = .truncated } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        const reply = try agent.readReply(&agent.model.?, &stream, &handler);
        try std.testing.expectEqual(@as(usize, 1), reply.len);
        try std.testing.expectEqualStrings("half", reply[0].message.text);
    }
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .item = .{ .tool_call = .{
                .call_id = "t1",
                .name = "read",
                .arguments_json = "{}",
            } } },
            .{ .stop = .{ .usage = .{}, .status = .truncated } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

test "readReply validates tool arguments: empty is an object, non-object rejects" {
    const gpa = std.testing.allocator;
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .item = .{ .tool_call = .{
                .call_id = "t1",
                .name = "read",
                .arguments_json = "",
            } } },
            .{ .stop = .{ .usage = .{} } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        const reply = try agent.readReply(&agent.model.?, &stream, &handler);
        try std.testing.expectEqual(@as(usize, 1), reply.len);
        try std.testing.expectEqualStrings("{}", reply[0].tool_call.arguments_json);
    }
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .item = .{ .tool_call = .{
                .call_id = "t1",
                .name = "read",
                .arguments_json = "[1,2]",
            } } },
            .{ .stop = .{ .usage = .{} } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

test "readReply rejects empty and duplicate call identifiers" {
    const gpa = std.testing.allocator;
    const Case = struct { events: []const llm.Event };
    const empty_id = [_]llm.Event{
        .{ .item = .{ .tool_call = .{
            .call_id = "",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .stop = .{ .usage = .{} } },
    };
    const duplicate = [_]llm.Event{
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .stop = .{ .usage = .{} } },
    };
    const cases = [_]Case{
        .{ .events = &empty_id },
        .{ .events = &duplicate },
    };
    for (cases) |case| {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        var stream: ScriptedStream = .{ .events = case.events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

test "readReply rejects incomplete or invalid reasoning proof" {
    const gpa = std.testing.allocator;
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .thinking = "weigh" },
            .{ .stop = .{ .usage = .{} } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.EmptyReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
    {
        var agent = openaiScriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .thinking = "weigh" },
            .{ .item = .{ .reasoning = .{ .encrypted = .{
                .text = "weigh",
                .id = "",
                .encrypted_content = "enc",
            } } } },
            .{ .stop = .{ .usage = .{} } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const events = [_]llm.Event{
            .{ .item = .{ .reasoning = .{ .redacted = "" } } },
            .{ .stop = .{ .usage = .{} } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

const ScheduleLog = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    launched: usize = 0,
    launched_peak: usize = 0,
    reads_running: std.atomic.Value(usize) = .init(0),
    mutation_overlap: bool = false,
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
        if (self.reads_running.load(.acquire) != 0) self.mutation_overlap = true;
        self.launched = 0;
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
        self.launched += 1;
        self.launched_peak = @max(self.launched_peak, self.launched);
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
        self.launched = 0;
    }

    fn cancelGroup(userdata: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
        const self: *ScheduleLog = @ptrCast(@alignCast(userdata));
        self.backend.vtable.groupCancel(self.backend.userdata, group, token);
        self.launched = 0;
    }
};

const probe = struct {
    fn mutates(name: []const u8) bool {
        return std.mem.eql(u8, name, "write");
    }

    fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
        _ = input_json;
        const log: *ScheduleLog = @ptrCast(@alignCast(context.io.userdata));
        if (mutates(name)) {
            log.recordMutation();
            return .{ .content = try context.gpa.dupe(u8, "ok"), .is_error = false };
        }
        _ = log.reads_running.fetchAdd(1, .acq_rel);
        defer _ = log.reads_running.fetchSub(1, .acq_rel);
        return .{ .content = try context.gpa.dupe(u8, "ok"), .is_error = false };
    }
};

test "a queued skill file joins the conversation at the round boundary" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "---\nname: zig-style\n---\nUse four spaces.\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "SKILL.md", .data = body });
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const source = try std.fs.path.join(
        gpa,
        &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "SKILL.md" },
    );
    defer gpa.free(source);

    var guard: tool.SkillGuard = .{ .working_directory = cwd };
    try guard.add(.{ .glob = "**/*.zig", .skill = "zig-style", .source = source });
    var agent = scriptedAgent(gpa);
    agent.skill_guard = &guard;
    defer agent.deinit();

    const Handler = struct {
        skill: []const u8 = "",
        count: usize = 0,

        fn onSkillLoaded(self: *@This(), skill: []const u8, _: []const u8) !void {
            self.skill = skill;
            self.count += 1;
        }
    };
    var handler: Handler = .{};
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };

    try std.testing.expect(!try agent.drainSkills(&turn, &handler));

    try guard.require(&.{ .gpa = gpa, .io = io, .path = "src/App.zig", .history = &.{} });
    try std.testing.expect(try agent.drainSkills(&turn, &handler));
    try std.testing.expectEqual(@as(usize, 1), handler.count);
    try std.testing.expectEqualStrings("zig-style", handler.skill);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    const message = agent.items.items[0].message;
    try std.testing.expectEqual(llm.Role.user, message.role);
    try std.testing.expect(std.mem.endsWith(u8, message.text, body));

    try std.testing.expect((try guard.refusal(&.{
        .gpa = gpa,
        .io = io,
        .path = "src/App.zig",
        .history = agent.items.items,
    })) == null);
    try std.testing.expect(!try agent.drainSkills(&turn, &handler));
}

test "the tool context carries the history below the reply" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const Dispatch = struct {
        var seen_count: usize = 0;
        var seen_text: []const u8 = "";

        fn mutates(name: []const u8) bool {
            return std.mem.eql(u8, name, "write");
        }

        fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
            _ = name;
            _ = input_json;
            seen_count = context.history.len;
            seen_text = if (context.history.len > 0) context.history[0].message.text else "";
            return .{ .content = try context.gpa.dupe(u8, "ok"), .is_error = false };
        }
    };

    try agent.appendUser("the older message");
    try agent.items.append(gpa, .{ .tool_call = .{
        .call_id = try gpa.dupe(u8, "w1"),
        .name = try gpa.dupe(u8, "write"),
        .arguments_json = try gpa.dupe(u8, "{}"),
    } });
    const reply = agent.items.items[1..];
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expect(try agent.runToolsWith(Dispatch, reply, &turn, &handler));

    try std.testing.expectEqual(@as(usize, 1), Dispatch.seen_count);
    try std.testing.expectEqualStrings("the older message", Dispatch.seen_text);
}

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

    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "r1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r2", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r3", .name = "read", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expect(try agent.runToolsWith(probe, &reply, &turn, &handler));

    try std.testing.expect(!log.mutation_overlap);
    try std.testing.expectEqual(@as(usize, 2), log.launched_peak);

    try std.testing.expectEqual(@as(usize, 4), agent.items.items.len);
    try std.testing.expectEqualStrings("r1", agent.items.items[0].tool_result.call_id);
    try std.testing.expectEqualStrings("r2", agent.items.items[1].tool_result.call_id);
    try std.testing.expectEqualStrings("w1", agent.items.items[2].tool_result.call_id);
    try std.testing.expectEqualStrings("r3", agent.items.items[3].tool_result.call_id);
    try std.testing.expectEqual(@as(usize, 4), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 4), handler.tool_result_count);
}

test "a burst of read-only calls runs at most the cap at a time" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var log: ScheduleLog = .init(threaded.io());

    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const call_count = read_only_calls_max + 8;
    var call_ids: [call_count][8]u8 = undefined;
    var ids: [call_count][]const u8 = undefined;
    var reply: [call_count]llm.Item = undefined;
    for (0..call_count) |index| {
        ids[index] = try std.fmt.bufPrint(&call_ids[index], "r{d}", .{index});
        reply[index] = .{ .tool_call = .{
            .call_id = ids[index],
            .name = "read",
            .arguments_json = "{}",
        } };
    }
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expect(try agent.runToolsWith(probe, &reply, &turn, &handler));

    try std.testing.expectEqual(read_only_calls_max, log.launched_peak);
    try std.testing.expectEqual(call_count, handler.tool_start_count);
    try std.testing.expectEqual(call_count, handler.tool_result_count);
    try std.testing.expectEqual(call_count, agent.items.items.len);
    for (agent.items.items, ids) |item, id| {
        try std.testing.expectEqualStrings(id, item.tool_result.call_id);
        try std.testing.expect(!item.tool_result.is_error);
    }
}

test "a barrier presents the reads before it before announcing its mutation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var agent = scriptedAgent(gpa);
    agent.io = threaded.io();
    defer agent.deinit();

    const Handler = struct {
        gpa: std.mem.Allocator,
        log: std.ArrayList(u8) = .empty,

        fn note(self: *@This(), mark: []const u8, name: []const u8) !void {
            try self.log.appendSlice(self.gpa, mark);
            try self.log.appendSlice(self.gpa, name);
        }
        fn onToolStart(self: *@This(), name: []const u8, _: []const u8) !void {
            try self.note("+", name);
        }
        fn onToolResult(
            self: *@This(),
            name: []const u8,
            _: []const u8,
            _: ?tool.Result.Summary,
            _: bool,
        ) !void {
            try self.note("-", name);
        }
        fn onUsage(_: *@This(), _: Stats) !void {}
    };
    var handler: Handler = .{ .gpa = gpa };
    defer handler.log.deinit(gpa);

    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "r1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r2", .name = "read", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expect(try agent.runToolsWith(fake_tools, &reply, &turn, &handler));

    try std.testing.expectEqualStrings("+read-read+write-write+read-read", handler.log.items);
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
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expectError(
        error.Canceled,
        agent.runToolsWith(probe, &reply, &turn, &handler),
    );
    try std.testing.expect(!log.mutation_overlap);
    try std.testing.expectEqual(@as(usize, 1), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
    try std.testing.expectEqualStrings("r1", agent.items.items[0].tool_result.call_id);
    try std.testing.expectEqualStrings("w1", agent.items.items[1].tool_result.call_id);
    try std.testing.expectEqualStrings("r3", agent.items.items[2].tool_result.call_id);
    try std.testing.expect(agent.items.items[1].tool_result.is_error);
    try std.testing.expect(agent.items.items[2].tool_result.is_error);
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

    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w2", .name = "write", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    _ = try agent.runToolsWith(probe, &reply, &turn, &handler);
}

test "runTools frees partial work at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runToolsUnderOom, .{});
}

const tool_round_events = [_]llm.Event{
    .{ .item = .{ .tool_call = .{
        .call_id = "t1",
        .name = "write",
        .arguments_json = "{}",
    } } },
    .{ .stop = .{ .usage = .{} } },
};

const end_turn_events = [_]llm.Event{
    .{ .text = "hi" },
    .{ .item = .{ .message = "hi" } },
    .{ .stop = .{ .usage = .{} } },
};

test "the round cap retains the completed rounds and fails the turn" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();
    const rounds_max = 3;
    agent.rounds_max = rounds_max;

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &tool_round_events } }},
    };
    try std.testing.expectError(error.TooManyToolRounds, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, rounds_max), fetch.sends);
    try std.testing.expectEqual(@as(usize, rounds_max), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, rounds_max), handler.checkpoint_count);
    try std.testing.expectEqual(@as(usize, 1 + 2 * rounds_max), agent.items.items.len);
}

test "a reply past the tool call cap aborts and fails the turn" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var call_ids: [tool_calls_max + 1][8]u8 = undefined;
    var overflow_events: [tool_calls_max + 2]llm.Event = undefined;
    for (0..tool_calls_max + 1) |index| {
        const call_id = try std.fmt.bufPrint(&call_ids[index], "t{d}", .{index});
        overflow_events[index] = .{ .item = .{ .tool_call = .{
            .call_id = call_id,
            .name = "write",
            .arguments_json = "{}",
        } } };
    }
    overflow_events[tool_calls_max + 1] = .{
        .stop = .{ .usage = .{ .input = 71, .output = 9 } },
    };

    var overflow_events_read: usize = 0;
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{
            .events = &overflow_events,
            .maybe_events_read = &overflow_events_read,
            .usage_so_far = .{ .input = 71 },
        } },
    } };
    agent.rounds_max = 2;
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);

    switch (outcome.disposition) {
        .failed => |err| try std.testing.expectEqual(error.TooManyToolCalls, err),
        else => return error.UnexpectedDisposition,
    }
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(tool_calls_max + 1, overflow_events_read);
    try std.testing.expectEqual(@as(usize, 1), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, 1), handler.checkpoint_count);
    try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
    try std.testing.expectEqual(@as(u64, 71), agent.stats.cache_usage.input);
    try std.testing.expectEqual(@as(u64, 0), agent.stats.cache_usage.output);
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
    try std.testing.expectEqual(@as(usize, 1), handler.checkpoint_count);
}

test "only a committed reply measures the context, while any prompt rates the cache" {
    const gpa = std.testing.allocator;

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
        try agent.appendUser("the first prompt");
        try std.testing.expect(agent.stats.context_tokens == null);
        agent.rollback(0);
        try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
    }

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const usage: llm.Usage = .{ .input = 10, .output = 20, .cache_read = 100 };
        const events = [_]llm.Event{
            .{ .item = .{ .message = "hi" } },
            .{ .stop = .{ .usage = usage } },
        };
        var fetch: ScriptedFetch = .{ .attempts = &.{.{ .stream = .{ .events = &events } }} };
        try agent.runWith(&fetch, "go", &handler);
        try std.testing.expectEqual(@as(?u64, 130), agent.stats.context_tokens);
        try std.testing.expectEqual(usage, agent.stats.cache_usage);
    }

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const rejected: llm.Usage = .{ .input = 7, .cache_read = 3 };
        const rejected_events = [_]llm.Event{
            .{ .stop = .{ .usage = rejected, .rejection = .invalid } },
        };
        var stream: ScriptedStream = .{ .events = &rejected_events };
        try std.testing.expectError(
            error.IncompleteReply,
            agent.readReply(&agent.model.?, &stream, &handler),
        );
        try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
        try std.testing.expectEqual(rejected, agent.stats.cache_usage);
    }

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        try agent.appendUser("an earlier prompt");
        seedContext(&agent, 130);
        const uncommitted: llm.Usage = .{ .input = 40, .output = 5, .cache_read = 60 };
        const events = [_]llm.Event{
            .{ .item = .{ .message = "hi" } },
            .{ .stop = .{ .usage = uncommitted } },
        };
        var stream: ScriptedStream = .{ .events = &events };
        _ = try agent.readReply(&agent.model.?, &stream, &handler);
        try std.testing.expectEqual(@as(?u64, 130), agent.stats.context_tokens);
        try std.testing.expectEqual(uncommitted, agent.stats.cache_usage);
    }

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        try agent.appendUser("an earlier prompt");
        seedContext(&agent, 130);
        const partial: llm.Usage = .{ .input = 40, .cache_read = 60 };
        var fetch: ScriptedFetch = .{ .attempts = &.{.{ .stream = .{
            .events = &.{},
            .usage_so_far = partial,
            .terminal_error = error.Canceled,
        } }} };
        const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
        try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
        try std.testing.expectEqual(@as(?u64, 130), agent.stats.context_tokens);
        try std.testing.expectEqual(partial, agent.stats.cache_usage);
    }
}

test "each commit publishes its measurement before the next round streams" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const call_events = [_]llm.Event{
        .{ .item = .{ .tool_call = .{
            .call_id = "r1",
            .name = "read",
            .arguments_json = "{}",
        } } },
        .{ .stop = .{ .usage = .{ .input = 100, .output = 20 } } },
    };
    const answer_events = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .input = 300, .output = 40 } } },
    };
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &call_events } },
        .{ .stream = .{ .events = &answer_events } },
    } };
    try agent.runWith(&fetch, "go", &handler);

    try std.testing.expectEqualSlices(
        ?u64,
        &.{ null, 120, 120, 340 },
        handler.published_context.items,
    );
    try std.testing.expectEqual(@as(?u64, 340), agent.stats.context_tokens);
}

test "a committed truncation is reported in the receipt; a resampled one is not" {
    const gpa = std.testing.allocator;
    const truncated_events = [_]llm.Event{
        .{ .text = "half an ans" },
        .{ .item = .{ .message = "half an ans" } },
        .{ .stop = .{ .usage = .{}, .status = .truncated } },
    };
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        var fetch: ScriptedFetch = .{
            .attempts = &.{.{ .stream = .{ .events = &truncated_events } }},
        };
        const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
        try std.testing.expect(std.meta.activeTag(outcome.disposition) == .completed);
        try std.testing.expectEqualStrings("half an ans", agent.items.items[1].message.text);
        try std.testing.expect(outcome.receipt.truncated);
    }
    {
        var log: SleepLog = .init(std.testing.io);
        var agent = scriptedAgent(gpa);
        agent.io = log.io();
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        const truncated_tool_events = [_]llm.Event{
            .{ .item = .{ .tool_call = .{
                .call_id = "t1",
                .name = "read",
                .arguments_json = "{}",
            } } },
            .{ .stop = .{ .usage = .{}, .status = .truncated } },
        };
        var fetch: ScriptedFetch = .{ .attempts = &.{
            .{ .stream = .{ .events = &truncated_tool_events } },
            .{ .stream = .{ .events = &end_turn_events } },
        } };
        const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
        try std.testing.expect(std.meta.activeTag(outcome.disposition) == .completed);
        try std.testing.expectEqualStrings("hi", agent.items.items[1].message.text);
        try std.testing.expect(!outcome.receipt.truncated);
    }
}

test "credential changes and token endpoint errors do not retry a request" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    for ([_]struct { failure: anyerror, disposition: std.meta.Tag(Outcome.Disposition) }{
        .{ .failure = error.CredentialReplaced, .disposition = .credential_replaced },
        .{ .failure = error.TokenGrantRejected, .disposition = .credential_rejected },
    }) |expected| {
        var fetch: ScriptedFetch = .{
            .attempts = &.{.{ .fail = expected.failure }},
        };
        const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
        try std.testing.expectEqual(
            expected.disposition,
            std.meta.activeTag(outcome.disposition),
        );
        try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    }
    for ([_]anyerror{
        error.TokenServiceUnavailable,
        error.TokenRequestFailed,
    }) |err| {
        var fetch: ScriptedFetch = .{ .attempts = &.{.{ .fail = err }} };
        try std.testing.expectError(err, agent.runWith(&fetch, "go", &handler));
        try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    }
}

test "run retries transient failures, resetting the stream before each reattempt" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .fail = error.ConnectionRefused },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Timeout } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 3), fetch.sends);
    try std.testing.expectEqual(@as(usize, 2), handler.stream_reset_count);
    try std.testing.expectEqualStrings(
        "2 failure ConnectionRefused\n3 failure Timeout\n",
        handler.retries.items,
    );
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqualStrings("hi", agent.items.items[1].message.text);
    try std.testing.expectEqualStrings("hi", handler.text.items);
}

test "run retries a streamed transient API error" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{
            .events = &.{},
            .terminal_error = error.ApiError,
            .usage_so_far = .{ .input = 7 },
            .stream_error_retryable = true,
            .retry_after_ms = 5000,
            .error_text = "Overloaded",
        } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), handler.stream_reset_count);
    try std.testing.expectEqualStrings("2 response Overloaded\n", handler.retries.items);
    try std.testing.expectEqual(@as(usize, 0), handler.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqual(@as(u64, 5000), log.slept_ms[0]);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
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
    try std.testing.expectEqualStrings(
        "2 failure Timeout\n3 failure Timeout\n",
        handler.retries.items,
    );
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

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{
            .events = &.{},
            .head_ok = false,
            .head_retryable = true,
            .retry_after_ms = 5000,
            .error_text = "Overloaded",
        } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqual(@as(u64, 5000), log.slept_ms[0]);
    try std.testing.expectEqual(@as(usize, 1), handler.stream_reset_count);
    try std.testing.expectEqualStrings("2 response Overloaded\n", handler.retries.items);
    try std.testing.expectEqualStrings("hi", handler.text.items);
}

test "a retry-after past the backoff cap fails the turn at once" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{
            .events = &.{},
            .head_ok = false,
            .head_retryable = true,
            .retry_after_ms = 3_600_000,
            .error_text = "429 Too Many Requests",
        } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try std.testing.expectError(error.ApiError, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    try std.testing.expectEqual(@as(usize, 0), handler.stream_reset_count);
    try std.testing.expectEqualStrings("429 Too Many Requests", handler.errors.items);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "a rejected credential renews once and repeats the request" {
    const gpa = std.testing.allocator;
    var log: SleepLog = .init(std.testing.io);
    var agent = scriptedAgent(gpa);
    agent.io = log.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{
            .{ .stream = .{
                .events = &.{},
                .head_ok = false,
                .head_unauthorized = true,
                .error_text = "401 Unauthorized: OAuth access token has been revoked.",
            } },
            .{ .stream = .{ .events = &end_turn_events } },
        },
        .renewal_changes = true,
    };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.renewals);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    try std.testing.expectEqualStrings(
        "2 response 401 Unauthorized: OAuth access token has been revoked.\n",
        handler.retries.items,
    );
    try std.testing.expectEqualStrings("hi", handler.text.items);
    try std.testing.expectEqualStrings("", handler.errors.items);
}

test "a credential that cannot renew reports the rejection at once" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{
            .{ .stream = .{
                .events = &.{},
                .head_ok = false,
                .head_unauthorized = true,
                .error_text = "401 Unauthorized: invalid x-api-key",
            } },
            .{ .stream = .{ .events = &end_turn_events } },
        },
    };
    try std.testing.expectError(error.ApiError, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.renewals);
    try std.testing.expectEqualStrings("401 Unauthorized: invalid x-api-key", handler.errors.items);

    var replaced: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{
            .events = &.{},
            .head_ok = false,
            .head_unauthorized = true,
        } }},
        .renewal_error = error.CredentialReplaced,
    };
    try std.testing.expectError(
        error.CredentialReplaced,
        agent.runWith(&replaced, "go", &handler),
    );
}

test "a rejection that outlives its renewal is reported after one repeat" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{
            .events = &.{},
            .head_ok = false,
            .head_unauthorized = true,
            .error_text = "401 Unauthorized: OAuth access token has been revoked.",
        } }},
        .renewal_changes = true,
    };
    try std.testing.expectError(error.ApiError, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.renewals);
    try std.testing.expectEqualStrings(
        "401 Unauthorized: OAuth access token has been revoked.",
        handler.errors.items,
    );
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

test "an API error retains completed rounds, reports, and fails the turn" {
    const gpa = std.testing.allocator;
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        var fetch: ScriptedFetch = .{ .attempts = &.{
            .{ .stream = .{ .events = &tool_round_events } },
            .{ .stream = .{
                .events = &.{},
                .terminal_error = error.ApiError,
                .error_text = "boom",
            } },
        } };
        try std.testing.expectError(error.ApiError, agent.runWith(&fetch, "go", &handler));
        try std.testing.expectEqualStrings("boom", handler.errors.items);
        try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
        try std.testing.expectEqualStrings("go", agent.items.items[0].message.text);
        try std.testing.expectEqualStrings("t1", agent.items.items[1].tool_call.call_id);
        try std.testing.expectEqualStrings("t1", agent.items.items[2].tool_result.call_id);
    }
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        var head_fetch: ScriptedFetch = .{
            .attempts = &.{
                .{ .stream = .{ .events = &.{}, .head_ok = false, .error_text = "denied" } },
            },
        };
        try std.testing.expectError(error.ApiError, agent.runWith(&head_fetch, "go", &handler));
        try std.testing.expectEqual(@as(usize, 1), head_fetch.sends);
        try std.testing.expectEqualStrings("denied", handler.errors.items);
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

test "a failed or canceled attempt still adopts the head's allowance" {
    const gpa = std.testing.allocator;
    const exhausted: llm.Quota = .{ .primary = .{ .used_percent = 100, .window_minutes = 300 } };

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        var fetch: ScriptedFetch = .{ .attempts = &.{
            .{ .stream = .{ .events = &.{}, .head_ok = false, .quota = exhausted } },
        } };
        try std.testing.expectError(error.ApiError, agent.runWith(&fetch, "go", &handler));
        try std.testing.expectEqual(@as(f64, 100), agent.stats.quota.?.primary.?.used_percent);
    }

    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();
        var fetch: ScriptedFetch = .{ .attempts = &.{
            .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled, .quota = exhausted } },
        } };
        try std.testing.expectError(error.Canceled, agent.runWith(&fetch, "go", &handler));
        try std.testing.expectEqual(@as(f64, 100), agent.stats.quota.?.primary.?.used_percent);
    }
}

test "the head that states an allowance stamps its own arrival" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    agent.stats.quota_seen_ms = 0;
    var stated: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{
            .events = &tool_round_events,
            .quota = .{ .primary = .{
                .used_percent = 12,
                .window_minutes = 300,
                .reset_seconds = 3180,
            } },
        } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    const outcome = agent.runTurnWith(&stated, fake_tools, "go", &handler);
    try std.testing.expect(outcome.disposition == .completed);
    const stamped = agent.stats.quota_seen_ms;
    try std.testing.expect(stamped > 0);
    try std.testing.expectEqual(@as(f64, 12), agent.stats.quota.?.primary.?.used_percent);

    var silent: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&silent, "again", &handler);
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expectEqual(@as(i64, 0), agent.stats.quota_seen_ms);
}

test "each committed round adopts a billing allowance" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const weekly: llm.Quota = .{ .primary = .{
        .used_percent = 1,
        .window_minutes = 10080,
        .reset_seconds = 3600,
    } };
    var fetch: ScriptedFetch = .{
        .attempts = &.{
            .{ .stream = .{ .events = &tool_round_events } },
            .{ .stream = .{ .events = &end_turn_events } },
        },
        .quota_to_fetch = weekly,
    };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(outcome.disposition == .completed);
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(@as(usize, 2), fetch.quota_fetches);
    try std.testing.expectEqual(@as(f64, 1), agent.stats.quota.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 10080), agent.stats.quota.?.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 3600), agent.stats.quota.?.primary.?.reset_seconds);
    try std.testing.expect(agent.stats.quota_seen_ms > 0);
}

test "a response head adopts the allowance before the reply streams" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{
            .events = &end_turn_events,
            .quota = .{ .primary = .{ .used_percent = 40, .window_minutes = 300 } },
        } }},
    };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(f64, 40), agent.stats.quota.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 300), agent.stats.quota.?.primary.?.window_minutes);
    try std.testing.expectEqual(@as(usize, 3), handler.usage_count);
}

test "a new turn drops the last turn's cache rate, allowance, and pool" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    agent.stats.cache_usage = .{ .input = 100, .cache_read = 900 };
    agent.stats.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };
    agent.stats.quota_seen_ms = 1;
    agent.stats.credits = .{ .total = 10, .used = 2 };
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .fail = error.Unexpected }},
    };
    try std.testing.expectError(error.Unexpected, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expectEqual(@as(i64, 0), agent.stats.quota_seen_ms);
    try std.testing.expect(agent.stats.credits == null);
}

test "a failed billing read leaves this turn's allowance and continues the turn" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const weekly: llm.Quota = .{ .primary = .{ .used_percent = 1, .window_minutes = 10080 } };
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{
            .events = &end_turn_events,
            .quota = weekly,
        } }},
        .quota_error = error.Timeout,
    };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.quota_fetches);
    try std.testing.expectEqual(@as(f64, 1), agent.stats.quota.?.primary.?.used_percent);
}

test "a canceled billing read keeps a finished reply" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }},
        .quota_error = error.Canceled,
    };
    try std.testing.expectError(error.Canceled, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.quota_fetches);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
}

test "an out-of-memory billing read fails the turn and keeps the reply" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }},
        .quota_error = error.OutOfMemory,
    };
    try std.testing.expectError(error.OutOfMemory, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.quota_fetches);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
}

test "a committed round reads the credit pool and reports it" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const pool = llm.Credits{ .total = 10, .used = 2.86 };
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }},
        .credits_to_fetch = pool,
    };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.credits_fetches);
    try std.testing.expectEqual(@as(f64, 10), agent.stats.credits.?.total);
    try std.testing.expectEqual(@as(f64, 2.86), agent.stats.credits.?.used);
}

test "a failed credit read at the start of a turn leaves no pool" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    agent.stats.credits = .{ .total = 10, .used = 2 };
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }},
        .credits_error = error.Timeout,
    };
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.credits_fetches);
    try std.testing.expect(agent.stats.credits == null);
}

test "a canceled credit read keeps a finished reply" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }},
        .credits_error = error.Canceled,
    };
    try std.testing.expectError(error.Canceled, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.credits_fetches);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
}

test "an out-of-memory credit read fails the turn and keeps the reply" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &end_turn_events } }},
        .credits_error = error.OutOfMemory,
    };
    try std.testing.expectError(error.OutOfMemory, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), fetch.credits_fetches);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
}

test "steering queued during a final reply stays queued" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.steering.push("steer");
    try agent.runWith(&fetch, "go", &handler);
    try std.testing.expectEqual(@as(usize, 1), fetch.sends);
    try std.testing.expectEqual(@as(usize, 0), handler.steer_count);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);

    const queued = try agent.steering.take();
    defer {
        for (queued) |message| gpa.free(message);
        gpa.free(queued);
    }
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try std.testing.expectEqualStrings("steer", queued[0]);
}

test "steering folds into a turn that a tool round keeps alive" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.steering.push("steer");
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(outcome.disposition == .completed);
    try std.testing.expectEqual(@as(usize, 2), fetch.sends);
    try std.testing.expectEqual(@as(usize, 1), handler.steer_count);
    try std.testing.expectEqual(@as(usize, 1), outcome.receipt.steering_committed_count);
    try std.testing.expectEqual(@as(usize, 5), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[3].message.role);
    try std.testing.expectEqualStrings("steer", agent.items.items[3].message.text);
    try std.testing.expectEqualStrings("hi", agent.items.items[4].message.text);

    const queued = try agent.steering.take();
    defer gpa.free(queued);
    try std.testing.expectEqual(@as(usize, 0), queued.len);
}

const fake_tools = struct {
    fn mutates(name: []const u8) bool {
        return std.mem.eql(u8, name, "write");
    }

    fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
        _ = name;
        _ = input_json;
        const content = try context.gpa.dupe(u8, "ok");
        errdefer context.gpa.free(content);
        return .{
            .content = content,
            .summary = .{ .text = try context.gpa.dupe(u8, "summary") },
            .is_error = false,
        };
    }
};

const raising_tools = struct {
    fn mutates(name: []const u8) bool {
        _ = name;
        return true;
    }

    fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
        _ = context;
        _ = name;
        _ = input_json;
        return error.Boom;
    }
};

const not_run_tools = struct {
    fn mutates(name: []const u8) bool {
        _ = name;
        return false;
    }

    fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
        _ = input_json;
        if (std.mem.eql(u8, name, "fail")) return error.NotRun;
        const content = try context.gpa.dupe(u8, "ok");
        errdefer context.gpa.free(content);
        return .{
            .content = content,
            .summary = .{ .text = try context.gpa.dupe(u8, "summary") },
            .is_error = false,
        };
    }
};

const closed_tools = struct {
    fn mutates(name: []const u8) bool {
        _ = name;
        return true;
    }

    fn run(context: *const tool.Context, name: []const u8, input_json: []const u8) !tool.Result {
        _ = context;
        _ = name;
        _ = input_json;
        return error.PresentationChannelClosed;
    }
};

test "a preparation failure dispatches nothing and commits no result slot" {
    for ([_]usize{ 0, 1, 2 }) |fail_at| {
        var failing: std.testing.FailingAllocator =
            .init(std.testing.allocator, .{ .fail_index = fail_at });
        const gpa = failing.allocator();
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        var handler: CaptureHandler = .{ .gpa = gpa };
        defer handler.deinit();

        const reply = [_]llm.Item{
            .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        };
        var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
        try std.testing.expectError(
            error.OutOfMemory,
            agent.runToolsWith(fake_tools, &reply, &turn, &handler),
        );
        try std.testing.expectEqual(@as(usize, 0), handler.tool_start_count);
        try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    }
}

test "a completed mutation's real result survives a callback failure" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var agent = scriptedAgent(gpa);
    agent.io = threaded.io();
    defer agent.deinit();

    const Handler = struct {
        fn onToolStart(_: *@This(), _: []const u8, _: []const u8) !void {}
        fn onToolResult(
            _: *@This(),
            _: []const u8,
            _: []const u8,
            maybe_summary: ?tool.Result.Summary,
            _: bool,
        ) !void {
            const summary = maybe_summary orelse return error.NoSummary;
            try std.testing.expectEqualStrings("summary", summary.text);
            return error.Boom;
        }
        fn onUsage(_: *@This(), _: Stats) !void {}
    };
    var handler: Handler = .{};
    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expectError(
        error.Boom,
        agent.runToolsWith(fake_tools, &reply, &turn, &handler),
    );
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqualStrings("ok", agent.items.items[0].tool_result.content);
    try std.testing.expect(!agent.items.items[0].tool_result.is_error);
}

test "a tool error named NotRun propagates and later results are harvested" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var agent = scriptedAgent(gpa);
    agent.io = threaded.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "t1", .name = "fail", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "t2", .name = "succeed", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expectError(
        error.NotRun,
        agent.runToolsWith(not_run_tools, &reply, &turn, &handler),
    );
    try std.testing.expectEqualStrings(
        unfinished_tool_result,
        agent.items.items[0].tool_result.content,
    );
    try std.testing.expectEqualStrings("ok", agent.items.items[1].tool_result.content);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
}

test "a mutation that raises retains the conservative unfinished-call result" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var agent = scriptedAgent(gpa);
    agent.io = threaded.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expectError(
        error.Boom,
        agent.runToolsWith(raising_tools, &reply, &turn, &handler),
    );
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expect(agent.items.items[0].tool_result.is_error);
    try std.testing.expectEqualStrings(
        unfinished_tool_result,
        agent.items.items[0].tool_result.content,
    );
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
}

test "a tool error matching the former presentation sentinel remains failed" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &tool_round_events } }},
    };

    const outcome = agent.runTurnWith(&fetch, closed_tools, "go", &handler);
    switch (outcome.disposition) {
        .failed => |err| try std.testing.expect(err == error.PresentationChannelClosed),
        else => return error.UnexpectedDisposition,
    }
}

test "cancellation after a completed tool round retains it at the checkpoint" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var agent = scriptedAgent(gpa);
    agent.io = threaded.io();
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.receipt.history_base);
    try std.testing.expectEqual(@as(usize, 3), outcome.receipt.history_end);
    try std.testing.expectEqualStrings("ok", agent.items.items[2].tool_result.content);
    try std.testing.expect(!agent.items.items[2].tool_result.is_error);
    try std.testing.expectEqual(@as(usize, 1), handler.tool_summary_count);
}

test "cancellation before the first reply returns exactly to the turn base" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } }},
    };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    try std.testing.expectEqual(outcome.receipt.history_base, outcome.receipt.history_end);
}

test "a canceled request's partial usage is folded into the cost stats" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    var fetch: ScriptedFetch = .{ .attempts = &.{.{ .stream = .{
        .events = &.{},
        .terminal_error = error.Canceled,
        .usage_so_far = .{ .input = 1_000_000, .cache_read = 200_000 },
    } }} };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expect(agent.stats.cost > 0);
    try std.testing.expectEqual(@as(u64, 1_000_000), agent.stats.cache_usage.input);
    try std.testing.expectEqual(@as(u64, 200_000), agent.stats.cache_usage.cache_read);
}

test "a cancel before any usage frame leaves this turn's cache rate intact" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const call_events = [_]llm.Event{
        .{ .item = .{ .tool_call = .{
            .call_id = "t1",
            .name = "write",
            .arguments_json = "{}",
        } } },
        .{ .stop = .{ .usage = .{ .input = 42 } } },
    };
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &call_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expectEqual(@as(u64, 42), agent.stats.cache_usage.input);
}

test "a cancel during the post-stop usage callback books terminal usage only once" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa, .fail_usage = true };
    defer handler.deinit();

    const events = [_]llm.Event{
        .{ .item = .{ .message = "hi" } },
        .{ .stop = .{ .usage = .{ .input = 1000 } } },
    };
    var fetch: ScriptedFetch = .{ .attempts = &.{.{ .stream = .{
        .events = &events,
        .usage_so_far = .{ .input = 1000 },
    } }} };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 1000), agent.stats.cache_usage.input);
}

test "a completed round is retained when a later steered reply is canceled" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    try agent.steering.push("steer");
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
    try std.testing.expectEqualStrings("go", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("t1", agent.items.items[1].tool_call.call_id);
    try std.testing.expectEqualStrings("t1", agent.items.items[2].tool_result.call_id);
    try std.testing.expectEqual(@as(usize, 0), outcome.receipt.steering_committed_count);
    const restored = try agent.steering.take();
    defer {
        for (restored) |message| gpa.free(message);
        gpa.free(restored);
    }
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    try std.testing.expectEqualStrings("steer", restored[0]);
}

test "the receipt reports the committed steering count and history span" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    try agent.steering.push("steer");
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .completed);
    try std.testing.expectEqual(@as(usize, 1), outcome.receipt.steering_committed_count);
    try std.testing.expectEqual(@as(usize, 5), outcome.receipt.history_end);
    try std.testing.expect(!outcome.receipt.truncated);
}
