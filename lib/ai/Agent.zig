//! Drives one user turn to completion. It appends the message, streams the
//! reply, runs the requested tools, and feeds the results back. It repeats
//! until the model asks for no more tools. Owns the conversation history.
//! Talks to the model through a neutral `provider.Client` and delegates
//! presentation to a handler.

const std = @import("std");

const llm = @import("llm.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");
const provider = @import("provider.zig");
const Steering = @import("Steering.zig");
const testing = @import("testing.zig");
const tool = @import("tool/root.zig");

const Agent = @This();

/// The per-turn bound on tool rounds. It is a guard against a runaway loop, not
/// a budget. A long task must never reach it. The user cancels a turn with Esc,
/// and a real loop grows the prompt until it hits the context limit first.
const rounds_max = 1000;

/// The placeholder shown for a redacted reasoning block (its content is encrypted).
const redacted_notice = "[redacted thinking]";

/// The conservative content for a reserved tool-result slot whose real result
/// never arrived. It does not claim the call never started. One wording covers a
/// call that was not started, was interrupted, raised without a result, or
/// changed the world and then recorded no result. Stored without an `Error:`
/// prefix, which the OpenAI serializer adds for error results. The consumer
/// shows the same wording for the call it fails, so the transcript and the
/// history cannot drift.
pub const unfinished_tool_result =
    "The tool stopped before Drinky recorded a result. " ++
    "Drinky does not know if the tool changed the system.";

gpa: std.mem.Allocator,
io: std.Io,
/// Each bash command inherits this process environment. The host owns it for the session.
environ: std.process.Environ,
/// The active account's transport, or null while signed out. The app refuses to
/// start a turn while signed out, so the internal uses assume one.
client: ?provider.Client,
model: ?Model,
system: []const u8,
effort: llm.Effort,
retry: net.Retry,
/// Bounds the bash tool's output window and runtime, handed to every tool call.
bash: tool.Context.Bash,
/// What the `describe_drinky` tool returns. The host owns the text and keeps it
/// alive for the session. An empty document means the host describes nothing.
document: []const u8,
/// The path-triggered skill rules, handed to every tool call. The host owns the
/// guard and keeps it alive for the session. Null means the host applies no
/// rule. The loaded skills belong to the conversation, so a reset forgets them.
skill_guard: ?*tool.SkillGuard,
items: std.ArrayList(llm.Item),
stats: Stats,
/// The context that the last committed reply measured, with the setup that
/// produced it. Null means no measurement describes the current history.
measured_context: ?MeasuredContext,
/// Steering messages the user submitted mid-turn, drained into the running turn
/// at each round boundary. Thread-safe: the UI thread pushes, and the worker takes.
steering: Steering,
/// The stable per-conversation prompt-cache routing key (used by OpenAI). Every
/// turn shares it until a deliberate reset rotates it.
cache_key: [32]u8,

/// The cumulative session cost, the two gauge measurements, and the latest
/// subscription allowance. Each message is priced against the model that
/// produced it, so the total stays correct across a mid-session `/model`
/// switch. A plain value type: it copies whole across the UI channel.
pub const Stats = struct {
    /// The session cost of every reply Drinky could price. It is an estimate at
    /// public rates, and a subscription pays none of it.
    cost: f64 = 0,
    /// The conversation context that the last committed reply measured. Null
    /// means no measurement describes the current history, or the way the next
    /// request renders it. Empty history is 0.
    context_tokens: ?u64 = 0,
    /// The prompt usage of the last request under the active cache key. An
    /// all-zero prompt hides the cache rate, so a cleared value reads as
    /// absent. A canceled attempt counts: its prompt was processed and billed.
    cache_usage: llm.Usage = .{},
    /// The active subscription account's remaining allowance, adopted from each
    /// response head that carries one. This includes a head whose stream then
    /// errors or is canceled, so an exhausted 429 still updates it. A head that
    /// omits one leaves it unchanged. The value is null until a head reports one.
    /// An account switch clears it. API-key accounts report none.
    quota: ?llm.Quota = null,
    /// The monotonic milliseconds at which a head last stated `quota`, counted
    /// on the clock that includes a suspended system, because a window runs on
    /// the server while the machine sleeps. A window states its reset relative
    /// to its own response, so a consumer subtracts this from its own reading of
    /// that clock to show the wait that is left. A head that omits the allowance
    /// leaves this alone, so a kept countdown keeps running down instead of
    /// starting again. It travels with the stats, so a failed turn and a
    /// canceled turn both carry the right age. The value is relative to this
    /// process alone, so a save must drop it and a restart must read it as
    /// unknown.
    quota_seen_ms: i64 = 0,
};

/// A reply that another model served than the request named. A provider can
/// switch a flagged request to a fallback model, so the handler reports the
/// switch instead of passing the reply off as the requested model's. The named
/// fields keep the two confusable names apart at the call site. Both slices
/// stay valid only for the duration of the callback.
pub const ModelMismatch = struct {
    requested: []const u8,
    served: []const u8,
};

/// One retry that is about to start, with the cause that ended the prior
/// attempt. The attempt number includes the initial request, so the first retry
/// is attempt two. A response slice stays valid only for the callback.
pub const RetryAttempt = struct {
    attempt: u32,
    cause: Cause,

    pub const Cause = union(enum) {
        /// A local request or stream failure. The error name identifies it.
        failure: anyerror,
        /// The error text from a provider response head or stream.
        response: []const u8,
    };
};

/// The receipt of one turn: the history span it produced, how far steering
/// commitment advanced, and whether a committed reply was cut short. Owns no
/// memory and stays valid only until another turn mutates the agent history.
pub const Receipt = struct {
    history_base: usize,
    history_end: usize,
    steering_committed_count: usize,
    /// A reply this turn committed stopped at the provider's output or context
    /// limit. The answer stands as authoritative but is incomplete. The
    /// presentation layer says so and does not pass it off as a full reply.
    truncated: bool = false,
};

/// A turn's outcome: its receipt plus how the turn ended. The receipt is always
/// present, so a receipt is never lost through an error union.
pub const Outcome = struct {
    receipt: Receipt,
    disposition: Disposition,

    pub const Disposition = union(enum) {
        completed,
        canceled,
        /// The presentation callback's event channel closed during the turn.
        closed,
        /// A store reload selected a credential for a different principal.
        credential_replaced,
        /// The provider rejected the selected client's refresh credential.
        credential_rejected,
        failed: anyerror,
    };
};

/// One measurement of the conversation context, with the request setup that
/// produced it. A later request renders the same history to the same tokens
/// only while the setup holds, so the gauge judges the measurement against it.
const MeasuredContext = struct {
    /// The whole prompt of the measuring request plus the output it produced.
    tokens: u64,
    /// The model the request named. A tokenizer belongs to its model. The name
    /// is copied, because a model outlives no catalog refresh.
    model: Model,
    /// The account that rendered the request. It selects account-specific system
    /// blocks and stored reasoning proofs.
    account: llm.Account,
    /// The control the request rendered. It decides the replay for Anthropic.
    reasoning: llm.Request.Reasoning,
};

/// The turn transaction's private bookkeeping. It holds the pre-turn history
/// length, the latest replay-valid checkpoint an abnormal exit rolls back to,
/// and the counts and flags surfaced in the receipt. It also retains (and owns)
/// a consumed-but-uncommitted steering batch until its following reply commits.
const TurnState = struct {
    base: usize,
    checkpoint: usize,
    steering_committed_count: usize = 0,
    truncated: bool = false,
    pending_steering: ?[][]u8 = null,
    /// The measurement of the latest reply, held until that reply commits. A
    /// reply that never commits is rolled back, so its measurement must not
    /// reach the gauge.
    pending_context: ?MeasuredContext = null,
    presentation_closed: bool = false,
};

/// One scheduled tool call. The concurrent runner writes `result`. The collector
/// moves it into the reserved history slot once the task has finished.
const Call = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
    /// The index in `Agent.items` of this call's reserved `tool_result` slot.
    result_index: usize = 0,
    result: State = .pending,
    /// Whether the real result has replaced the reserved slot's unfinished-call
    /// content, so a later harvest or collection does not move it twice.
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

/// The production fetch: `provider.Client.send` on the active account. A seam
/// like `runToolsWith`'s `Dispatch`, so tests can script whole turns.
const ClientFetch = struct {
    client: *provider.Client,

    const Stream = provider.Stream;

    fn send(self: *ClientFetch, stream: *provider.Stream, request: *const llm.Request) !void {
        return self.client.send(stream, request);
    }

    fn renewCredential(self: *ClientFetch) !bool {
        return self.client.renewCredential();
    }
};

/// Duplicate one complete borrowed assistant output into the history shape and
/// bind a reasoning proof to the exact producing account. This is the sole
/// ownership boundary for provider output strings.
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

/// Whether `bytes` is a valid top-level JSON object. A parse failure is not
/// valid. Only an allocation failure propagates.
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

/// Start a fresh conversation and keep its account, model, and configuration.
/// Call this only between turns, when no worker can own history or steering.
pub fn resetConversation(self: *Agent) void {
    self.rollback(0);
    self.stats = .{};
    self.measured_context = null;
    self.steering.clear();
    self.cache_key = generateCacheKey(self.io);
}

/// Switch the account and the model together, effective on the next turn. The
/// client carries both the transport and the reasoning-replay account, so the
/// pair is one atomic step. A model is never paired with a foreign vendor's
/// client. History is untouched. The new account drops reasoning it did not
/// produce.
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
    // An allowance belongs to the account whose response reported it. Session
    // totals span account switches, but this point-in-time gauge must not.
    if (account_changed) self.stats.quota = null;
    // The provider isolates a cache per principal, and it keys the entry on the
    // rendered model too, so either change makes the measured rate foreign. A
    // replaced description keeps the name and can still render another
    // reasoning control, so the comparison reads every described part.
    if (account_changed or model_changed) self.stats.cache_usage = .{};
    // The context gauge judges its own measurement against the new setup, so a
    // switch back to the measured setup shows the count again.
    self.refreshContext();
}

/// Drop the active account and leave the agent signed out. `model` is kept as
/// the last-shown value. The account-specific allowance and cache rate are
/// forgotten. The context gauge stands, because a signed-out Drinky sends no
/// request that renders the history in another way.
pub fn signOut(self: *Agent) void {
    self.client = null;
    self.stats.quota = null;
    self.stats.cache_usage = .{};
    self.refreshContext();
}

/// Forget everything bound to the provider principal behind `account`: its
/// replay proofs, its cache rate, and its allowance gauge. A credential
/// replacement can put another principal in the same account slot, and none of
/// this state crosses that boundary. The account itself stays authenticated,
/// so a caller that drops the account calls `signOut` or `switchTo` as well.
///
/// The context gauge keys on the account slot, which is not the principal. The
/// next principal renders the same prompt bytes today, so a dropped proof is
/// the only thing that voids the measurement here. Metadata of a principal that
/// ever reaches the prompt must void it here too.
pub fn dropAccountEvidence(self: *Agent, account: llm.Account) void {
    self.dropReasoning(account);
    // Both gauges hold what the last response of the active account reported,
    // so only that account can own them.
    const client = self.client orelse return;
    if (client.account() == account) {
        self.stats.quota = null;
        self.stats.cache_usage = .{};
    }
}

/// Remove replay proofs produced by one account slot. A successful credential
/// replacement calls this before that slot can represent another principal. A
/// dropped proof shortens the history, so the measured context no longer
/// describes it.
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

/// Switch the reasoning-effort level. It takes effect on the next turn.
pub fn setEffort(self: *Agent, effort: llm.Effort) void {
    // Anthropic renders `output_config.effort` into the prompt and states that
    // a change always invalidates the cached message blocks. Two levels that
    // fold onto one wire form render the same bytes, so they share one cache
    // and the rate survives.
    if (self.model) |model| {
        const rendered_before = model.reasoning(self.effort);
        const rendered_after = model.reasoning(effort);
        if (!rendered_before.eql(rendered_after)) self.stats.cache_usage = .{};
    }
    self.effort = effort;
    // The same history renders to the same tokens, unless the new effort takes
    // the stored reasoning out of the prompt or puts it back.
    self.refreshContext();
}

/// Publish the measurement to the context gauge, or hide it while the next
/// request renders the measured history in another way.
///
/// The gauge is a cache of `contextShown`, because `Stats` copies whole across
/// the UI channel. Every change of the history, the measurement, or the request
/// setup calls this, so the two never disagree. A new mutation point must call
/// it too.
fn refreshContext(self: *Agent) void {
    self.stats.context_tokens = self.contextShown();
}

/// The context the gauge shows. Empty history holds exactly zero tokens,
/// measured or not. A measurement holds while the next request renders the same
/// prompt around the same history. Anything else returns null, because Drinky
/// counts no token itself.
fn contextShown(self: *const Agent) ?u64 {
    if (self.items.items.len == 0) return 0;
    const measured = self.measured_context orelse return null;
    // A tokenizer belongs to its model. Anthropic states that its models from
    // 4.7 on count the same text about 30 percent higher.
    // Without a model no request goes out, so nothing states how this history
    // renders.
    const model = self.model orelse return null;
    if (!measured.model.sameName(model.name())) return null;
    // A signed-out Drinky sends nothing, so no request renders this history
    // differently. The next account decides that.
    const client = self.client orelse return measured.tokens;
    const account = client.account();
    // The count covers the whole prompt: the system blocks, the tools, the
    // history, and the output. The account renders all of that around the
    // history. It decides which stored proofs replay, and an Anthropic
    // subscription or Console request also leads with the Claude Code identity
    // that an API key omits. So another account states another number.
    if (account != measured.account) return null;
    // One account is left, and only the rendered reasoning control can still
    // move a proof. Anthropic drops every thinking block unless the request
    // names an effort, so a model change that flips the replay takes each proof
    // of this account out of the prompt, or puts it back.
    const reasoning = model.reasoning(self.effort);
    const vendor = account.provider();
    if (reasoning.replaysReasoning(vendor) == measured.reasoning.replaysReasoning(vendor))
        return measured.tokens;
    return if (self.holdsProofOf(account)) null else measured.tokens;
}

/// Whether the history holds one stored reasoning proof of `account`. Only such
/// a proof can enter or leave the prompt of that account.
///
/// A serializer also drops an incomplete proof. This scan does not repeat that
/// test, because `dupeOutput` refuses a reply whose proof is empty, so every
/// stored proof is complete.
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

/// Run one user turn as a checkpointed transaction, stream output through
/// `handler`, and return its outcome. Never returns an error: every exit yields
/// a receipt, so a receipt is never lost through an error union. Signed out (a
/// state the app refuses to start a turn in) yields a failed disposition.
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

/// The error-returning seam for the reply/round-loop tests.
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

/// Run one user turn as a checkpointed transaction and return its outcome. Every
/// exit — completion, cancellation, channel close, or failure — yields a
/// receipt. An abnormal exit does not unwind the whole turn. It rolls history
/// back to the latest valid checkpoint and returns any consumed-but-uncommitted
/// steering to the queue. The checkpoint retains every completed round and its
/// tool results.
fn runTurn(self: *Agent, fetch: anytype, user_text: []const u8, handler: anytype) Outcome {
    return self.runTurnWith(fetch, tool, user_text, handler);
}

/// `runTurn` with an injectable tool dispatch, so a test can drive the whole
/// round loop against controllable fake tools rather than the real registry.
fn runTurnWith(
    self: *Agent,
    fetch: anytype,
    comptime Dispatch: type,
    user_text: []const u8,
    handler: anytype,
) Outcome {
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

/// Preserve callback error provenance in turn state. Only a presentation
/// callback's channel closure is teardown. The same error from a tool or
/// transport remains an ordinary failure.
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
    while (round < rounds_max) : (round += 1) {
        const reply = try self.fetchReply(fetch, turn, handler);
        const ran_tools = try self.runToolsWith(Dispatch, reply, turn, handler);
        // A no-tool reply commits here. A tool-calling reply committed itself
        // together with its reserved results before dispatch.
        if (!ran_tools) try self.commitRound(turn, handler);
        // Send every skill file that this round asked for, before the steering
        // of the user. A tool met a file that a rule guards, so the model needs
        // the rules of that file for whatever it does next.
        const loaded = try self.drainSkills(turn, handler);
        // A reply that asks for no tool ends the turn, and a queued steering
        // message stays for review. The user wrote it against a reply that was
        // still streaming, so the finished reply can change what they want to
        // send. A skill file keeps the turn alive, because it is guidance that
        // Drinky owes the model before whatever the model does next.
        if (!ran_tools and !loaded) return;
        // Fold mid-turn steering in before the next round.
        try self.drainSteering(turn, handler);
    }
    return error.TooManyToolRounds;
}

/// Roll an abnormally-ended turn back to its latest valid checkpoint and return
/// the consumed-but-uncommitted steering batch to the queue. Allocation-free.
fn rollbackTurn(self: *Agent, turn: *TurnState) void {
    self.rollback(turn.checkpoint);
    if (turn.pending_steering) |steering| {
        var batch = steering;
        self.steering.restoreTaken(&batch);
        turn.pending_steering = null;
    }
}

/// Commit the latest round: advance the checkpoint, tell the handler, and
/// publish the gauges when this commit adopted a new context measurement. The
/// usage frame of a round arrives before its commit, so a gauge that waits for
/// the next frame trails one committed reply for a whole round.
fn commitRound(self: *Agent, turn: *TurnState, handler: anytype) !void {
    const measured = self.advanceCheckpoint(turn);
    notifyCheckpoint(handler);
    if (measured) try presentation(&turn.presentation_closed, handler.onUsage(self.stats));
}

/// Advance the checkpoint to commit the latest reply (and any reserved
/// tool-result slots). The same advance commits the steering batch that preceded
/// it, and the context that the reply measured. Returns whether it adopted a new
/// measurement. The advance itself never fails, because a commit and the release
/// of its steering batch must not come apart.
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

/// Tell presentation handlers that every event they accepted so far now belongs
/// to committed history. Most agent tests use partial handlers and do not need
/// this UI-specific frontier.
fn notifyCheckpoint(handler: anytype) void {
    if (comptime @hasDecl(@TypeOf(handler.*), "onCheckpoint")) handler.onCheckpoint();
}

fn freeSteeringBatch(gpa: std.mem.Allocator, batch: [][]u8) void {
    for (batch) |message| gpa.free(message);
    gpa.free(batch);
}

/// Deliver every skill file that the guard queued during this round, each as
/// one user message. The message carries the whole skill file, so the guard
/// proves it from the history alone on the next check. A rolled-back turn drops
/// the message, and the next call that needs the skill queues it again.
/// Returns whether anything was delivered.
fn drainSkills(self: *Agent, turn: *TurnState, handler: anytype) !bool {
    const guard = self.skill_guard orelse return false;
    var delivered = false;
    // One pass per rule at most, because a delivery leaves the queue.
    for (0..tool.SkillGuard.rules_max) |_| {
        // The current history settles a queued rule whose proof arrived by
        // another route, an earlier delivery of this pass included.
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

/// Tell a presentation handler that one skill file entered the conversation.
/// Most agent tests use partial handlers, so a handler without this callback
/// still drives a turn.
fn notifySkill(handler: anytype, skill: []const u8, source: []const u8) !void {
    if (comptime @hasDecl(@TypeOf(handler.*), "onSkillLoaded"))
        try handler.onSkillLoaded(skill, source);
}

/// Deliver every queued steering message as one combined user message, appended
/// to history and reported. On success the taken batch is retained in turn state
/// until its following reply commits. This lets an abnormal exit before then
/// return it to the queue. A failed delivery returns it at once. The caller
/// decides that the turn continues, so an empty queue is not an outcome it reads.
fn drainSteering(self: *Agent, turn: *TurnState, handler: anytype) !void {
    var pending = try self.steering.take();
    if (pending.len == 0) {
        self.gpa.free(pending);
        return;
    }
    // A failed delivery restores the whole batch ahead of messages submitted
    // since the take. It does not allocate or expose a partial batch. The move
    // below guards this: once turn state owns the batch, `rollbackTurn` restores
    // it. A second restore hands the queue one batch under two owners.
    errdefer if (turn.pending_steering == null) self.steering.restoreTaken(&pending);
    const combined = try Steering.join(self.gpa, pending);
    defer self.gpa.free(combined);
    try self.appendUser(combined);
    try presentation(&turn.presentation_closed, handler.onSteering(combined, pending.len));
    std.debug.assert(turn.pending_steering == null);
    turn.pending_steering = pending;
}

/// Stream one assistant reply and retry transient failures. Only whole
/// requests are safe to retry, so a failed attempt's partial reply is discarded
/// (history untouched). `handler.onStreamReset` clears partial output and reports
/// the next attempt with its cause. Returns the reply's items, already appended
/// to history. An API error is retried when its head or streamed event marks it
/// transient and the retry policy allows another try (see `net.Retry.allows`). An
/// exhausted or permanent error is reported through `handler.onError`. It surfaces
/// as `error.ApiError`, which rolls the turn back to its latest checkpoint.
///
/// A head that rejects the credential takes one renewal and one repeat outside
/// that policy, because another Drinky instance can have rotated the token this
/// one holds. A renewal that changes nothing reports the failure as it stands.
fn fetchReply(
    self: *Agent,
    fetch: anytype,
    turn: *TurnState,
    handler: anytype,
) ![]const llm.Item {
    const model = self.model orelse return error.NoModel;
    const request: llm.Request = .{
        .model = model.name(),
        // A provider that requires an output limit gets the one its own list
        // stated. A model that states none takes the floor, which truncates a
        // long reply, and `Model.outputLimitUnknown` marks such a model in a
        // picker.
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
        // The response head carries the subscription allowance before any events,
        // so adopt it as soon as the stream is established. A stream that then
        // errors, is canceled, or never reaches its terminal `.stop` still
        // updates the gauge. The most visible case is an exhausted 429 that
        // reports a spent account. A head that reports none leaves the last-known
        // allowance. The stamp uses the clock the interface ages it against, so
        // the countdown measures from this head and not from the terminal event
        // of a long stream.
        if (stream.quotaSoFar()) |quota| {
            self.stats.quota = quota;
            self.stats.quota_seen_ms = std.Io.Timestamp.now(self.io, .boot).toMilliseconds();
        }

        if (!stream.ok()) {
            // The provider rejected the credential. Another instance can have
            // rotated the token this one still holds, so renew it once and
            // repeat the request. Nothing streamed yet, so the repeat loses no
            // output.
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
                // A cancel that interrupts the read before its terminal `.stop`
                // still records whatever usage the provider delivered so far.
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

/// Report the retry that is about to start, so the handler clears the rejected stream.
fn notifyRetry(
    turn: *TurnState,
    attempt: u32,
    cause: *const RetryAttempt.Cause,
    handler: anytype,
) !void {
    const retry: RetryAttempt = .{ .attempt = attempt, .cause = cause.* };
    try presentation(&turn.presentation_closed, handler.onStreamReset(&retry));
}

/// Wait before the retry after a failed attempt: the server's `retry-after`
/// (capped) or exponential backoff. A cancel during the wait aborts the turn.
fn backoff(self: *Agent, failure: net.Retry.Failure) !void {
    const delay_ms = self.retry.backoffMs(failure);
    const bounded: u64 = @min(delay_ms, std.math.maxInt(i64));
    try self.io.sleep(.fromMilliseconds(@intCast(bounded)), .awake);
}

/// Transient request failures worth a retry. A user cancel or channel close
/// never is. The agent does not retry a token endpoint response because the
/// token is single-use.
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

/// Free and drop every history item from `base` on. Capacity is retained so a
/// rolled-back turn does not thrash the list backing.
fn rollback(self: *Agent, base: usize) void {
    for (self.items.items[base..]) |item| freeItem(self.gpa, item);
    self.items.shrinkRetainingCapacity(base);
    // A dropped item can carry the proof that a skill is loaded, so the guard
    // searches the shortened history again.
    if (self.skill_guard) |guard| guard.forget();
    // The rollback keeps every committed reply, so the measurement survives. An
    // emptied history reads as zero again.
    self.refreshContext();
}

/// Free one history item's owned strings. An empty string frees as a no-op.
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
    // The first message of a conversation ends the zero that empty history
    // states, and no reply has measured this text. A message that follows a
    // measured reply leaves that measurement alone, like every other item the
    // turn appends.
    self.refreshContext();
}

/// The conversation context one request reports: its whole prompt plus the
/// output it produced. Saturating, because the counts arrive from the provider
/// stream unchecked.
fn contextTokens(usage: *const llm.Usage) u64 {
    return usage.input +| usage.cache_read +| usage.cache_write +| usage.output;
}

/// Fold one message's usage into the totals, priced with `model`. The model is
/// threaded from the request so billing cannot drift when `/model` changes
/// `self.model`.
fn recordUsage(self: *Agent, model: *const Model, usage: *const llm.Usage) void {
    if (model.cost(usage)) |cost| self.stats.cost += cost;
    // The prompt of an accepted request is processed and billed whole, even
    // when the stream is canceled before its reply ends, so its hit rate is
    // final as soon as the counts arrive.
    self.stats.cache_usage = usage.*;
}

/// The model that prices one reply: the requested one, or the one the response
/// names as the model that served it. Drinky knows no rate for a model it did
/// not request, so a served reply carries no price. A served name that no model
/// can hold keeps the requested name and drops the price, because the rates of
/// one model never price another. The session total then counts nothing for
/// that reply.
fn pricingModel(requested: *const Model, served_name: []const u8) Model {
    if (served_name.len == 0 or requested.sameName(served_name)) return requested.*;
    return Model.init(served_name) catch {
        var unpriced = requested.*;
        unpriced.price = null;
        return unpriced;
    };
}

/// Record a stream's nonzero running usage unless its terminal event already did.
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

/// Read one streamed assistant message to completion, record usage, and append
/// its items to history. The reply is built locally and committed only once
/// complete, so a stream or API error leaves history untouched. The whole
/// request can then be retried without a duplicated or partial message. The
/// returned slice views the committed tail of `self.items`. It stays valid until
/// the next append (which `runTools` performs only after the reply is read).
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

    while (try stream.next()) |event| {
        if (event == .stop) {
            maybe_stop = event.stop;
            break;
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
    // The model that really served the reply prices it, so a provider-side
    // fallback bills under its own name.
    const priced_model = pricingModel(model, stop.model);
    // Terminal usage is billable even when replay validation rejects the reply
    // and the request is retried.
    self.recordUsage(&priced_model, &stop.usage);
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
    // A terminal reply that produced no assistant item at all is distinct from a
    // cut-short one. A resample is still worth a retry, but the exhausted-retry
    // report must say the model returned nothing rather than blame the stream.
    if (reply_items.items.len == 0) return error.EmptyReply;
    // A switch reports only for a committed reply, like the truncation flag: a
    // durable event block ends the open streamed message, so a report on a
    // rejected attempt leaves partial text that the retry's stream reset
    // cannot discard. The attempt that lands reports the switch. It reports
    // before the commit below, so a closed presentation channel cannot fail
    // the reply after history already owns its items.
    if (stop.model.len != 0 and !model.sameName(stop.model))
        try presentation(presentation_closed, handler.onModelMismatch(.{
            .requested = model.name(),
            .served = stop.model,
        }));

    const start = self.items.items.len;
    try self.items.appendSlice(gpa, reply_items.items);
    // The reply now belongs to the history, so its own report of the whole
    // prompt plus the output measures that history exactly. Every rejection
    // path returned above, so a discarded attempt never measures anything. The
    // checkpoint adopts the measurement, because a round that fails before that
    // point rolls this reply back out of the history again. The requested model
    // names it, because the next request goes out under that model.
    if (self.client) |client| turn.pending_context = .{
        .tokens = contextTokens(&stop.usage),
        .model = model.*,
        .account = client.account(),
        .reasoning = model.reasoning(self.effort),
    };
    // Only a committed reply's cutoff is worth a report: a rejected truncation
    // is retried, and a resampled attempt can finish.
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
        // Display only: the call runs from the committed reply, so a half
        // received argument list never reaches a tool.
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

/// The concurrent read-only task body, monomorphized per `Dispatch` so the real
/// turn loop keeps a direct call.
fn Runner(comptime Dispatch: type) type {
    return struct {
        fn run(call: *Call, context: *const tool.Context) void {
            call.result = .{ .finished = Dispatch.run(context, call.name, call.input_json) };
        }
    };
}

/// Run the assistant's tool calls through the real tool registry.
fn runTools(self: *Agent, reply: []const llm.Item, turn: *TurnState, handler: anytype) !bool {
    return self.runToolsWith(tool, reply, turn, handler);
}

/// Run every tool the assistant asked for. Each result is committed in call
/// order so each `tool_result` maps back to its `tool_call`. `Dispatch` names
/// the tool source (`mutates` and `run`). Tests inject controllable tools into
/// this path.
///
/// A conservative error result is reserved in history for every call. The
/// round is committed (checkpoint advanced) before anything is announced or
/// dispatched. So no mutation can change the world with no result recorded.
/// Contiguous read-only calls run concurrently. A mutating call is a barrier.
/// It awaits, transfers, and presents every earlier read before it announces
/// itself, and then runs alone. Any failure (a mid-turn cancel included) reaps
/// in-flight tasks and harvests their finished results into the reserved slots.
/// This leaves the committed round replay-valid. Returns false when no tools
/// were asked.
fn runToolsWith(
    self: *Agent,
    comptime Dispatch: type,
    reply: []const llm.Item,
    turn: *TurnState,
    handler: anytype,
) !bool {
    var call_list: std.ArrayList(Call) = .empty;
    defer call_list.deinit(self.gpa);
    // Collect the calls before the results are reserved. The reservation append
    // can move the items backing array and invalidate `reply`. But the borrowed
    // id, name, and argument strings are separate heap allocations that stay valid.
    for (reply) |item| switch (item) {
        .tool_call => |call| try call_list.append(
            self.gpa,
            .{ .id = call.call_id, .name = call.name, .input_json = call.arguments_json },
        ),
        else => {},
    };
    const calls = call_list.items;
    if (calls.len == 0) return false;
    // The conversation below this reply, by index: the reservation below can
    // move the items backing array, but never these items. The subtraction is
    // only correct because the reply is always the tail of the history, on
    // every path that reaches this function. The saturation alone bounds the
    // index and proves nothing more.
    const history_end = self.items.items.len -| reply.len;

    // Reserve one unfinished-call error result per call and commit the whole round
    // (reply + results) before any side effect can occur. A preparation failure
    // announces and dispatches nothing. The turn rolls back the reply.
    try self.reserveResults(calls);
    try self.commitRound(turn, handler);

    const context: tool.Context = .{
        .gpa = self.gpa,
        .io = self.io,
        .environ = self.environ,
        .bash = self.bash,
        .document = self.document,
        .skill_guard = self.skill_guard,
        // The reply that asked for these calls stays out, so a skill that this
        // reply reads cannot license a write that the same reply asked for.
        .history = self.items.items[0..history_end],
    };
    var group: std.Io.Group = .init;
    // On any early exit, reap in-flight tasks, then move every successful,
    // not-yet-moved result into its reserved slot. Errored or never-run calls
    // keep the conservative unfinished-call result. This allocates nothing.
    errdefer {
        group.cancel(self.io);
        self.harvestResults(calls);
    }

    for (calls) |*call| {
        const mutates = Dispatch.mutates(call.name);
        if (mutates) {
            // Drain earlier reads so the mutation cannot race one, and transfer
            // and present them in call order. The emptied group is reused. Both
            // happen before the announce, so presentation never shows a later
            // call start above an earlier call's result. A cancel at the barrier
            // never announces a mutation that did not run.
            try group.await(self.io);
            group = .init;
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
        }
    }
    try group.await(self.io);
    try self.presentReady(calls, turn, handler);
    return true;
}

/// Append one unfinished-call error `tool_result` per call and record each slot's
/// index on its `Call`. Capacity is reserved up front so the appends cannot fail
/// after the first. On a mid-run failure this frees the current call's partial
/// dupes while the turn rollback frees the slots already committed.
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

/// Present every completed, not-yet-moved call in call order and move each result
/// into its slot before its callback. Stops at the first call whose result is
/// not yet available (a barrier awaits only the reads dispatched before it).
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

/// Move a completed call's owned result content into its reserved slot and then
/// present it. The move frees the unfinished-call content it replaces. It is
/// allocation-free and precedes the fallible callback, so a callback failure
/// leaves provider-visible history honest. A call that raised and returned no
/// result propagates its error and leaves the unfinished-call result intact.
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

/// After tasks are reaped, move every successful, not-yet-moved result into its
/// slot. An errored or never-run call keeps its unfinished-call result. No allocation.
fn harvestResults(self: *Agent, calls: []Call) void {
    for (calls) |*call| {
        if (call.moved) continue;
        if (call.result == .pending) continue;
        var result = call.takeFinished() catch continue;
        defer result.deinit(self.gpa);
        self.transferResult(call, &result);
    }
}

/// Move a completed result's owned content into its reserved slot. This replaces
/// and frees the unfinished-call content the slot held. The result retains every other
/// owned field for its deferred `deinit`.
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

/// Whether a call already committed in *this reply* carries `id`, so a repeated
/// identifier is rejected before it enters history. Uniqueness is deliberately
/// scoped to one reply. That is what the wire format requires: a second call
/// that shares an id inside one response is unanswerable (one result cannot
/// address both). An id that reappears in a later round is already paired with
/// its own result and replays unambiguously. A rejection there fails a turn over
/// a harmless provider quirk.
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
    // An oversize stream reproduces on the same request, so it is not retried.
    try std.testing.expect(!retryableError(error.StreamResponseTooLarge));
    // A retry meets the same wire order, so a correlation failure fails the turn
    // at once instead of spending the budget on the same outcome.
    try std.testing.expect(!retryableError(error.UncorrelatedReply));
    // The provider's fallback holds for the conversation, so a retry meets the
    // same unknown model and only spends the budget.
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
    // Compares the whole struct, so the per-model buckets and their count must
    // also be back to default, not just the cumulative totals.
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

test "an account change or sign-out clears the previous account's quota" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const same_account = agent.client.?;
    var sonnet = testing.model("claude-sonnet-4-6");
    sonnet.efforts.remove(.xhigh);
    agent.stats.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };

    // A model change within one account keeps that account's latest allowance.
    agent.switchTo(same_account, sonnet);
    try std.testing.expect(agent.stats.quota != null);

    // A switch across accounts must not present the old account's allowance as current.
    const openai_client = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .openai_api = "sk-test" },
        .{},
    );
    const openai_model = testing.model("gpt-5.6-sol");
    agent.switchTo(openai_client, openai_model);
    try std.testing.expect(agent.stats.quota == null);

    agent.stats.quota = .{ .secondary = .{ .used_percent = 75, .window_minutes = 10080 } };
    agent.signOut();
    try std.testing.expect(agent.stats.quota == null);
}

// The provider keys its cache on the principal, the model, and the rendered
// effort, so a change to any of the three makes the measured rate foreign. Two
// effort levels that fold onto one wire form write the same bytes and share
// one cache, so the rate survives that change.
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

    // This model names no xhigh, so that level folds onto high and the change
    // writes the same bytes.
    agent.switchTo(same_account, sonnet);
    agent.setEffort(.high);
    agent.stats.cache_usage = usage;
    agent.setEffort(.xhigh);
    try std.testing.expectEqual(usage, agent.stats.cache_usage);

    // Another principal owns another cache.
    const other_account = provider.Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_api = "key" },
        .{},
    );
    agent.switchTo(other_account, agent.model.?);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    // The provider keys its entry on the rendered model too.
    agent.stats.cache_usage = usage;
    agent.switchTo(other_account, testing.model("claude-opus-4-8"));
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    // A fetch replaces the description of a model and keeps its name. A
    // narrowed ladder renders another effort control, so the rate goes with it.
    agent.stats.cache_usage = usage;
    var narrowed = testing.model("claude-opus-4-8");
    narrowed.efforts.remove(.max);
    agent.switchTo(other_account, narrowed);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    // A sign-out has no account left to attribute a rate to.
    agent.stats.cache_usage = usage;
    agent.signOut();
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);
}

// The context gauge shows a measurement, and Drinky counts no token itself. So
// the measurement holds exactly while the next request renders the same prompt
// around the same history. A tokenizer belongs to its model: Anthropic counts
// the same text about 30 percent higher from Claude 4.7 on. The account renders
// everything around the history. Under one account, only the rendered effort
// still moves a proof, because Anthropic replays a thinking block only under a
// named effort. The measurement carries the setup it describes, so a switch back
// to that setup shows the count again.
test "the context gauge holds while the tokenizer and the replayed reasoning hold" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const subscription = agent.client.?;
    const opus = agent.model.?;
    try agent.appendUser("committed context");
    try appendProof(&agent, .anthropic_subscription);
    agent.setEffort(.high);
    seedContext(&agent, 1020);

    // Another named effort keeps every thinking block in the prompt.
    agent.setEffort(.max);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    // A fetch can replace the description of opus with one that takes no level.
    // Such a model omits the effort control, which takes every thinking block
    // out of the prompt. The count no longer describes what goes out.
    var closed = opus;
    closed.efforts_denied = true;
    agent.switchTo(subscription, closed);
    try std.testing.expect(agent.stats.context_tokens == null);

    // Back under a named effort the proof replays again, so the count returns.
    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    // Another account renders another prompt, and it cannot replay this proof.
    const console = provider.Client.init(gpa, std.testing.io, .{ .anthropic_console = "k" }, .{});
    agent.switchTo(console, opus);
    try std.testing.expect(agent.stats.context_tokens == null);
    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    // A signed-out Drinky sends nothing, so the count stands until an account
    // that renders the history in another way replaces it.
    agent.signOut();
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);
    agent.switchTo(console, opus);
    try std.testing.expect(agent.stats.context_tokens == null);

    // The rule holds whatever account went before, so the gauge never depends
    // on the order of the switches.
    agent.signOut();
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);
    agent.switchTo(subscription, opus);

    // Another model counts the same history with another tokenizer.
    agent.switchTo(subscription, testing.model("claude-sonnet-4-6"));
    try std.testing.expect(agent.stats.context_tokens == null);
    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);

    // Empty history holds exactly zero tokens, so a reset needs no measurement.
    agent.resetConversation();
    try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
}

// The measured count covers the whole prompt, not the history alone, and the
// account renders everything around that history. An Anthropic subscription or
// Console request leads with the Claude Code identity that an API key omits, so
// the count of one account states nothing about another. A history with no
// stored proof changes nothing about that.
test "an account switch hides the count, and a switch back restores it" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const subscription = agent.client.?;
    const opus = agent.model.?;
    try agent.appendUser("committed context");
    agent.setEffort(.high);
    seedContext(&agent, 1020);

    const console = provider.Client.init(gpa, std.testing.io, .{ .anthropic_console = "k" }, .{});
    agent.switchTo(console, opus);
    try std.testing.expect(agent.stats.context_tokens == null);

    // The measurement waits for its own setup, so the switch back shows it.
    agent.switchTo(subscription, opus);
    try std.testing.expectEqual(@as(?u64, 1020), agent.stats.context_tokens);
}

// A setup change moves a token only when it takes a stored proof out of the
// prompt of the active account, or puts one back.
test "the context gauge survives every effort change that replays the same reasoning" {
    const gpa = std.testing.allocator;
    var anthropic_agent = scriptedAgent(gpa);
    defer anthropic_agent.deinit();

    const subscription = anthropic_agent.client.?;
    try anthropic_agent.appendUser("committed context");
    anthropic_agent.setEffort(.high);
    seedContext(&anthropic_agent, 1020);

    // A description that takes no level omits the effort control, but this
    // history holds no proof that the omission can take out of the prompt.
    var closed = anthropic_agent.model.?;
    closed.efforts_denied = true;
    anthropic_agent.switchTo(subscription, closed);
    try std.testing.expectEqual(@as(?u64, 1020), anthropic_agent.stats.context_tokens);

    // Sonnet 4.6 folds xhigh onto high. Both name an effort, so the proof of
    // this account replays either way and the count stands.
    const sonnet = testing.model("claude-sonnet-4-6");
    anthropic_agent.switchTo(subscription, sonnet);
    try appendProof(&anthropic_agent, .anthropic_subscription);
    anthropic_agent.setEffort(.high);
    seedContext(&anthropic_agent, 1020);
    anthropic_agent.setEffort(.xhigh);
    try std.testing.expectEqual(@as(?u64, 1020), anthropic_agent.stats.context_tokens);

    var openai_agent = openaiScriptedAgent(gpa);
    defer openai_agent.deinit();
    try openai_agent.appendUser("committed context");
    try appendProof(&openai_agent, .openai_api);
    openai_agent.setEffort(.high);
    seedContext(&openai_agent, 1020);

    // OpenAI names an effort at every level and keeps the encrypted item.
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
        .{ .anthropic_subscription = undefined },
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

    // Produced by sonnet while `self.model` is opus: pricing must follow the
    // passed model ($3, sonnet), not `self.model` ($5, opus).
    agent.switchTo(client, opus);
    agent.recordUsage(&sonnet, &one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);

    // An opus turn blends both rates: sonnet $3 + opus $5.
    agent.recordUsage(&opus, &one_million);
    try std.testing.expectApproxEqAbs(@as(f64, 8), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 1_000_000), agent.stats.cache_usage.input);
}

// A model that no source priced adds no cost at all. Drinky states no rate it
// does not know, so such a reply leaves the total where it stood.
test "an unpriced model adds no cost to the session total" {
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();

    const priced = testing.model("priced");
    agent.recordUsage(&priced, &.{ .input = 1_000_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);

    const unpriced = testing.bareModel("unpriced");
    agent.recordUsage(&unpriced, &.{ .input = 2_000_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 3), agent.stats.cost, 1e-9);
    // The cache gauge reads the last prompt whatever its price.
    try std.testing.expectEqual(@as(u64, 2_000_000), agent.stats.cache_usage.input);
}

const ScriptedStream = struct {
    events: []const llm.Event,
    index: usize = 0,
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

// A scripted fetch for `runWith`. Each send consumes the next attempt (the last
// repeats) and either fails outright or hands out a fresh copy of its stream.
const ScriptedFetch = struct {
    attempts: []const Attempt,
    sends: usize = 0,
    renewals: usize = 0,
    /// What a renewal reports: a subscription that takes a newer token reports
    /// true, and an API key reports false.
    renewal_changes: bool = false,
    renewal_error: ?anyerror = null,

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
};

// An io seam that records each requested sleep in milliseconds and returns at
// once, so retry backoffs are observable with no real wait.
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
    // The delivered batch is consumed but retained until its following reply.
    try std.testing.expect(turn.pending_steering != null);
    try std.testing.expectEqual(@as(usize, 0), turn.steering_committed_count);

    // An empty queue delivers nothing, so history and the report stand.
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

    // A trailing user item, as a round's tool results leave it: the Agent
    // appends a separate item, and the Anthropic serializer merges the run.
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

    // A handler canceled while it reports the batch: a mid-turn Esc that races
    // the round-boundary drain.
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
    /// Every streamed tool call as `name arguments`, one per line.
    streamed_tools: std.ArrayList(u8) = .empty,
    /// Every reported model switch as `requested served`, one per line.
    model_mismatches: std.ArrayList(u8) = .empty,
    /// Every retry as `attempt cause-kind cause`, one per line.
    retries: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    /// Every context measurement the agent published, in order.
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
        .{ .anthropic_subscription = undefined },
        .{},
    );
    return Agent.init(gpa, std.testing.io, client, .{
        .model = model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
}

/// Seed the measurement that a committed reply under the current setup leaves.
fn seedContext(agent: *Agent, tokens: u64) void {
    agent.measured_context = .{
        .tokens = tokens,
        .model = agent.model.?,
        .account = agent.client.?.account(),
        .reasoning = agent.model.?.reasoning(agent.effort),
    };
    agent.refreshContext();
}

/// Append one stored reasoning proof of `account` to the history. Every string
/// is owned, because `deinit` frees the whole item.
fn appendProof(agent: *Agent, account: llm.Account) !void {
    const gpa = agent.gpa;
    const text = try gpa.dupe(u8, "think");
    errdefer gpa.free(text);
    const proof = try gpa.dupe(u8, "proof");
    errdefer gpa.free(proof);
    const replay: llm.Item.Reasoning.Replay = switch (account) {
        inline .anthropic_subscription,
        .anthropic_api,
        .anthropic_console,
        => |tag| @unionInit(
            llm.Item.Reasoning.Replay,
            @tagName(tag),
            .{ .signature = .{ .text = text, .signature = proof } },
        ),
        inline .openai_subscription, .openai_api => |tag| replay: {
            const id = try gpa.dupe(u8, "rs_1");
            break :replay @unionInit(
                llm.Item.Reasoning.Replay,
                @tagName(tag),
                .{ .text = text, .id = id, .encrypted_content = proof },
            );
        },
    };
    try agent.items.append(gpa, .{ .reasoning = .{ .replay = replay } });
}

fn openaiScriptedAgent(gpa: std.mem.Allocator) Agent {
    const model = testing.model("gpt-5.6-sol");
    const client = provider.Client.init(gpa, std.testing.io, .{ .openai_api = "sk-test" }, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
}

fn anthropicStream(io: std.Io, reader: *std.Io.Reader, idle_ms: u64) provider.Stream {
    var stream: provider.Stream = .{ .anthropic_subscription = undefined };
    stream.anthropic_subscription.gpa = std.testing.allocator;
    stream.anthropic_subscription.io = io;
    stream.anthropic_subscription.idle_ms = idle_ms;
    stream.anthropic_subscription.budget = .{ .max = net.stream_response_bytes_max };
    stream.anthropic_subscription.body = reader;
    stream.anthropic_subscription.frame_arena = .init(std.testing.allocator);
    stream.anthropic_subscription.beginDecode();
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
    stream.openai_api.frame_arena = .init(std.testing.allocator);
    stream.openai_api.beginDecode();
    stream.openai_api.usage = .{};
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

// A provider can switch a flagged request to a fallback model. The stop names
// the model that served the reply, so the switch reports instead of passing as
// the requested model. A stop that names the requested model, or none, reports
// nothing.
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

    // A rejected attempt reports no switch: a durable event block ends the
    // open streamed message, the retry's stream reset then cannot discard the
    // partial text, and the retried reply duplicates it.
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

// The provider bills a switched request at the fallback's rates, so the ledger
// must price the reply at the model that served it and attribute the usage to
// that model's bucket. The cache rate takes the same reply, because the
// fallback keeps serving the conversation.
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

    // The requested model served the reply, so its own rates price it.
    try std.testing.expectEqual(agent.model.?.cost(&usage), agent.stats.cost);
    try std.testing.expectEqual(usage, agent.stats.cache_usage);
}

// Drinky knows no rate for a model it did not request, so the reply carries no
// price and adds nothing to the total. A provider-side fallback must not fail
// the turn.
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
    // The reply reports the switch, so the user sees which model answered.
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-mythos-5\n",
        handler.model_mismatches.items,
    );
}

// A served name arrives from the provider stream unchecked, so it can be longer
// than a model name Drinky holds. Such a name states no rate either, so the
// rates of the requested model must never price its reply.
test "readReply keeps a reply that a model with an over-long name served" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const served = "c" ** (Model.name_bytes_max + 1);
    // The requested model prices this usage, so a fallback to it is visible.
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

// The name and the argument fragments of a tool call are display only. They
// reach the handler as they stream, and only the completed item enters history,
// so no tool ever runs on half-received arguments.
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
    // The display events retain nothing of their own.
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
}

test "readReply records terminal usage before rejecting an invalid reply" {
    const gpa = std.testing.allocator;
    // A terminal truncated tool reply is rejected, but its billed usage remains.
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
    // An empty completed reply preserves the same accounting behavior.
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
    // Invalid completed item data is latched. Remaining display content is
    // ignored while the stream drains through terminal usage.
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

    // A large message then a tool call, and no stop event: each attempt
    // allocates item memory and then fails.
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

    // One warm-up attempt settles the reusable capacities (the item list, the
    // handler buffers) so the measured window isolates per-attempt retention.
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

    // Retained bytes must not scale with attempts. A session-lifetime arena
    // keeps each attempt's items and adds at least `big` per attempt.
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

    // Each appended item is freed exactly once (the leak-checking allocator
    // proves it). The user message stays.
    agent.rollback(base);
    try std.testing.expectEqual(base, agent.items.items.len);
    try std.testing.expectEqualStrings("keep me", agent.items.items[base - 1].message.text);
}

fn readReplyUnderOom(allocator: std.mem.Allocator) !void {
    var agent = scriptedAgent(allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = allocator };
    defer handler.deinit();

    // One reply that exercises every multi-string item builder.
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
    defer stream.anthropic_subscription.deinitDecode();
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
    defer stream.openai_api.deinitDecode();
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

    // Anthropic reports usage before message_stop resolves refusal as unsupported.
    {
        const body =
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11}}}\n\n" ++
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}," ++
            "\"usage\":{\"output_tokens\":7}}\n\n" ++
            "data: {\"type\":\"message_stop\"}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = anthropicStream(threaded.io(), &reader, 60_000);
        defer stream.anthropic_subscription.deinitDecode();
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
    // OpenAI refusal frames drain through response.completed and its usage.
    {
        const body =
            "data: {\"type\":\"response.refusal.delta\",\"delta\":\"no\"}\n\n" ++
            "data: {\"type\":\"response.refusal.done\",\"refusal\":\"no\"}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"," ++
            "\"usage\":{\"input_tokens\":13,\"output_tokens\":5}}}\n\n";
        var reader: std.Io.Reader = .fixed(body);
        var stream = openaiStream(threaded.io(), &reader);
        defer stream.openai_api.deinitDecode();
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
    // An incomplete function item is retryable, but the rejected attempt is
    // still included in accounting.
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
        defer stream.openai_api.deinitDecode();
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

test "readReply separates OpenAI reasoning summary parts with a blank line" {
    // Two summary parts share one reasoning item and arrive with no text between
    // them. The rising summary_index on the second part.added is the only seam,
    // so both the committed reply and the streamed handler must read "a\n\nb".
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
    defer stream.openai_api.deinitDecode();
    var agent = openaiScriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("a\n\nb", reply[0].reasoning.replay.openai_api.text);
    try std.testing.expectEqual(
        llm.Account.openai_api,
        std.meta.activeTag(reply[0].reasoning.replay),
    );
    try std.testing.expectEqualStrings("enc", reply[0].reasoning.replay.openai_api.encrypted_content);
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.replay.openai_api.id);
    try std.testing.expectEqualStrings("a\n\nb", handler.thinking.items);
}

test "readReply separates a redacted Anthropic block from the reasoning before it" {
    // This module displays the placeholder for a redacted block, and it cannot
    // put a blank line in front of that text. The frame that opens the block
    // carries the seam instead, so the handler must read the two apart.
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
    defer stream.anthropic_subscription.deinitDecode();
    var agent = scriptedAgent(std.testing.allocator);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = std.testing.allocator };
    defer handler.deinit();

    const reply = try agent.readReply(&agent.model.?, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 2), reply.len);
    try std.testing.expectEqualStrings(
        "weigh it",
        reply[0].reasoning.replay.anthropic_subscription.signature.text,
    );
    try std.testing.expectEqualStrings(
        "enc",
        reply[1].reasoning.replay.anthropic_subscription.redacted,
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
        defer stream.anthropic_subscription.deinitDecode();
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
        defer stream.openai_api.deinitDecode();
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
        defer stream.anthropic_subscription.deinitDecode();
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
        defer stream.openai_api.deinitDecode();
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
        reply[0].reasoning.replay.anthropic_subscription.signature.text,
    );
    try std.testing.expectEqual(
        llm.Account.anthropic_subscription,
        std.meta.activeTag(reply[0].reasoning.replay),
    );
    try std.testing.expectEqualStrings(
        "sig",
        reply[0].reasoning.replay.anthropic_subscription.signature.signature,
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
        reply[0].reasoning.replay.anthropic_subscription.redacted,
    );
    try std.testing.expectEqualStrings(
        "",
        reply[1].reasoning.replay.anthropic_subscription.signature.text,
    );
    try std.testing.expectEqualStrings(
        "sigonly",
        reply[1].reasoning.replay.anthropic_subscription.signature.signature,
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

    // Each run keeps its own proof. Text stays between the runs it streamed
    // between and does not sink below them.
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
    try std.testing.expectEqualStrings("A", reply[0].reasoning.replay.openai_api.text);
    try std.testing.expectEqualStrings(
        "encA",
        reply[0].reasoning.replay.openai_api.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_a", reply[0].reasoning.replay.openai_api.id);
    try std.testing.expectEqualStrings("B", reply[1].reasoning.replay.openai_api.text);
    try std.testing.expectEqualStrings(
        "encB",
        reply[1].reasoning.replay.openai_api.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_b", reply[1].reasoning.replay.openai_api.id);
    try std.testing.expectEqualStrings("between", reply[2].message.text);
    try std.testing.expectEqualStrings("C", reply[3].reasoning.replay.openai_api.text);
    try std.testing.expectEqualStrings(
        "encC",
        reply[3].reasoning.replay.openai_api.encrypted_content,
    );
    try std.testing.expectEqualStrings("rs_c", reply[3].reasoning.replay.openai_api.id);
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
        llm.Account.openai_api,
        std.meta.activeTag(reply[0].reasoning.replay),
    );
    try std.testing.expectEqualStrings("rs_1", reply[0].reasoning.replay.openai_api.id);
    try std.testing.expectEqualStrings("hmm", reply[0].reasoning.replay.openai_api.text);
    try std.testing.expectEqualStrings(
        "enc",
        reply[0].reasoning.replay.openai_api.encrypted_content,
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
        .{ .openai_api = "sk-test" },
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
    agent.dropReasoning(.anthropic_subscription);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(
        llm.Account.openai_api,
        std.meta.activeTag(agent.items.items[0].reasoning.replay),
    );
    // A shorter history leaves no valid measurement of it.
    try std.testing.expect(agent.stats.context_tokens == null);
    agent.dropReasoning(.openai_api);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
    // Empty history holds exactly zero tokens, measured or not.
    try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
}

test "dropped account evidence takes the allowance of the active account only" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    const quota: llm.Quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };

    // Both gauges belong to the account whose response reported them, so
    // another account's replaced credential leaves them alone.
    const usage: llm.Usage = .{ .input = 100, .cache_read = 900 };
    agent.stats.quota = quota;
    agent.stats.cache_usage = usage;
    agent.dropAccountEvidence(.openai_api);
    try std.testing.expect(agent.stats.quota != null);
    try std.testing.expectEqual(usage, agent.stats.cache_usage);

    // A replaced credential of the active account takes them, because the next
    // principal has its own allowance and its own isolated cache.
    agent.dropAccountEvidence(.anthropic_subscription);
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expectEqual(llm.Usage{}, agent.stats.cache_usage);

    // A signed-out agent has no account to compare, and drops nothing.
    agent.signOut();
    agent.stats.quota = quota;
    agent.dropAccountEvidence(.anthropic_subscription);
    try std.testing.expect(agent.stats.quota != null);
}

test "readReply retains a truncated tool-free reply but rejects a truncated tool call" {
    const gpa = std.testing.allocator;
    // A truncated answer with no tool call is an authoritative reply and commits.
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
    // A truncated reply that still holds a tool call cannot be answered. Reject it.
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
    // Empty closed arguments commit as an empty object.
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
    // A non-object final argument is not replayable verbatim. Reject it.
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
    // A presented run with no complete reasoning event retains nothing, so the
    // reply is empty rather than invalid.
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
    // A structurally incomplete identified proof cannot bind to the account.
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
    // Anthropic redacted: an empty encrypted payload is not replayable either.
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

// A scheduling seam that wraps a real threaded executor. It counts read-only
// tasks dispatched into the current group generation and records their peak.
// Via an atomic that each read body holds while it runs, it flags a mutation
// that ran while a read was still active. The launch counter is main-thread
// only. The executing count is atomic because read bodies run on worker threads.
const ScheduleLog = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    launched: usize = 0,
    launched_peak: usize = 0,
    reads_running: std.atomic.Value(usize) = .init(0),
    mutation_overlap: bool = false,
    // When set, the next group await reports cancellation and does not drain, so
    // the caller's errdefer must reap the launched reads through `cancelGroup`.
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
        // The barrier already drained earlier reads, so the mutation closes the
        // launch generation: a later read starts a fresh one, not a peak of three.
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

// A controllable tool source for `runToolsWith`: "write" mutates, and everything
// else is read-only. A mutation notes any scheduling overlap.
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
        // A read holds the executing count for its whole body, so a mutation that
        // sees a nonzero count caught a read the barrier failed to drain.
        _ = log.reads_running.fetchAdd(1, .acq_rel);
        defer _ = log.reads_running.fetchSub(1, .acq_rel);
        return .{ .content = try context.gpa.dupe(u8, "ok"), .is_error = false };
    }
};

// A tool that meets a guarded file asks Drinky for the skill. The round boundary
// sends it as one user message, so the model holds the rules for its next act.
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

    // Records what the handler was told, so the report and the message can be
    // compared against one delivery.
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

    // Nothing waits, so the boundary sends nothing and the turn can end.
    try std.testing.expect(!try agent.drainSkills(&turn, &handler));

    try guard.require(&.{ .gpa = gpa, .io = io, .path = "src/App.zig", .history = &.{} });
    try std.testing.expect(try agent.drainSkills(&turn, &handler));
    try std.testing.expectEqual(@as(usize, 1), handler.count);
    try std.testing.expectEqualStrings("zig-style", handler.skill);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    const message = agent.items.items[0].message;
    try std.testing.expectEqual(llm.Role.user, message.role);
    try std.testing.expect(std.mem.endsWith(u8, message.text, body));

    // The message is the proof, so a write of the same file goes ahead now.
    try std.testing.expect((try guard.refusal(&.{
        .gpa = gpa,
        .io = io,
        .path = "src/App.zig",
        .history = agent.items.items,
    })) == null);
    // One delivery per queued rule: the queue is empty again.
    try std.testing.expect(!try agent.drainSkills(&turn, &handler));
}

// The skill guard proves a loaded skill against the conversation the tools
// receive. That conversation must stop below the reply, or a skill that this
// reply reads licenses a write that the same reply already asked for.
test "the tool context carries the history below the reply" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Records what one call saw. A tool reads the context, so only a tool can
    // report it.
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

    // The history holds one older message and then the reply, the way a real
    // turn leaves it.
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

    // Two reads, a mutation, a read: the leading reads run concurrently, the
    // mutation drains them first, and the trailing read starts only after it.
    const reply = [_]llm.Item{
        .{ .tool_call = .{ .call_id = "r1", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r2", .name = "read", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "w1", .name = "write", .arguments_json = "{}" } },
        .{ .tool_call = .{ .call_id = "r3", .name = "read", .arguments_json = "{}" } },
    };
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expect(try agent.runToolsWith(probe, &reply, &turn, &handler));

    // The mutation never ran while a read was still active...
    try std.testing.expect(!log.mutation_overlap);
    // ...yet the two leading reads were dispatched concurrently.
    try std.testing.expectEqual(@as(usize, 2), log.launched_peak);

    // Results stay in call order, one per call.
    try std.testing.expectEqual(@as(usize, 4), agent.items.items.len);
    try std.testing.expectEqualStrings("r1", agent.items.items[0].tool_result.call_id);
    try std.testing.expectEqualStrings("r2", agent.items.items[1].tool_result.call_id);
    try std.testing.expectEqualStrings("w1", agent.items.items[2].tool_result.call_id);
    try std.testing.expectEqualStrings("r3", agent.items.items[3].tool_result.call_id);
    try std.testing.expectEqual(@as(usize, 4), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 4), handler.tool_result_count);
}

test "a barrier presents the reads before it before announcing its mutation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var agent = scriptedAgent(gpa);
    agent.io = threaded.io();
    defer agent.deinit();

    // Records the presentation sequence itself, since call totals alone cannot
    // tell a start that precedes an earlier call's result from one that follows.
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
        // The commit of the round publishes the gauges. This test drives that
        // path directly, so it takes the callback and logs nothing.
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

    // The read's result lands before the mutation is announced, and the trailing
    // read's after it, so the presentation never runs backwards in call order.
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
    // Cancel at the barrier await with no drain. This forces the errdefer's
    // live-task reap. The launched read's finished result is harvested into its
    // reserved slot, the mutation never runs, and the trailing read never starts.
    var turn: TurnState = .{ .base = 0, .checkpoint = 0 };
    try std.testing.expectError(
        error.Canceled,
        agent.runToolsWith(probe, &reply, &turn, &handler),
    );
    try std.testing.expect(!log.mutation_overlap);
    // Only r1 was announced. The barrier drains ahead of its own announce, so a
    // mutation canceled there is never presented as started, and r3 past it
    // never begins.
    try std.testing.expectEqual(@as(usize, 1), handler.tool_start_count);
    try std.testing.expectEqual(@as(usize, 0), handler.tool_result_count);
    // The whole round's result slots stay committed and replay-valid: one slot
    // per call, in call order, and unresolved ones keep their unfinished-call result.
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

    // All-mutation calls run inline (no task spawn), so the sweep of the
    // tool-result builder is deterministic under every injected failure.
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

    // A model that asks for a tool every round overruns the bound after exactly
    // `rounds_max` rounds. Each round's side effects are real, so every
    // completed round is retained at the latest checkpoint and the turn fails.
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &tool_round_events } }},
    };
    try std.testing.expectError(error.TooManyToolRounds, agent.runWith(&fetch, "go", &handler));
    try std.testing.expectEqual(@as(usize, rounds_max), fetch.sends);
    try std.testing.expectEqual(@as(usize, rounds_max), handler.tool_result_count);
    try std.testing.expectEqual(@as(usize, rounds_max), handler.checkpoint_count);
    // Prompt plus one tool_call/tool_result pair per completed round.
    try std.testing.expectEqual(@as(usize, 1 + 2 * rounds_max), agent.items.items.len);
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

// Only a reply that stays in the history measures that history. A rejected
// reply is retried and never reaches the append, a round that breaks before its
// checkpoint rolls the reply back out, and a canceled attempt rolls its prompt
// back, so all three leave the count on the last committed reply. The prompt of
// an accepted request is processed and billed whole either way, so its hit rate
// is final as soon as the counts arrive.
test "only a committed reply measures the context, while any prompt rates the cache" {
    const gpa = std.testing.allocator;

    // Empty history holds exactly zero tokens. The first prompt ends that
    // certainty, because no reply has measured that text. A rollback to an
    // empty history states the zero again.
    {
        var agent = scriptedAgent(gpa);
        defer agent.deinit();
        try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
        try agent.appendUser("the first prompt");
        try std.testing.expect(agent.stats.context_tokens == null);
        agent.rollback(0);
        try std.testing.expectEqual(@as(?u64, 0), agent.stats.context_tokens);
    }

    // A committed reply measures the whole prompt plus its own output.
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

    // A rejected reply returns before the append, so it rates the cache and
    // measures nothing. Its retry then commits and measures.
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

    // A reply that reaches no checkpoint leaves the history with its round, so
    // the count waits for the checkpoint and stands where it was.
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

    // A cancel rolls the prompt back to the checkpoint that the last count
    // already describes, so that count stands and the rate still moves.
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

// The usage frame of a round arrives before the commit of that round, so the
// commit publishes the gauges itself. Otherwise a tool round leaves the whole
// next round with the measurement of the reply before it.
test "each commit publishes its measurement before the next round streams" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Round one asks for a tool, and round two answers. Every prompt grows, so
    // each measurement differs from the one before it.
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

    // The stream of a round reports the measurement of the round before it, and
    // the commit that follows reports its own. So the second round streams with
    // 120 already on the gauge, not with the null of a fresh conversation.
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
    // A truncated tool-free answer commits and the turn completes, so the receipt
    // is the only place the cutoff can still be reported.
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
    // A truncation rejected because it holds a tool call resamples. The attempt
    // that finishes cleanly is the one committed, so nothing is reported as cut short.
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

    // attempts_max is 3: a connect failure, a mid-stream failure, then success.
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

    // Without the hint the first backoff is backoff_ms_initial (500ms).
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

    // The head is retryable, but it asks for a wait the 16 s cap cannot serve.
    // No wait inside the cap clears the failure, so the turn spends no further
    // attempt.
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

// Another Drinky instance can refresh the credential this one holds, which
// revokes its access token. The rejected head must renew the credential once
// and repeat the request, so the turn never sees the failure.
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
    // The repeat carries the new credential at once, so it waits for nothing.
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

    // An API key comes from the environment, so no renewal can replace it.
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

    // A renewal that finds another principal stops the turn with its own error.
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

    // Every attempt is rejected, so the renewed credential fails too. One
    // renewal per reply bounds the repeats, whatever the provider answers.
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
    // A committed tool round, then an API error in the next request: the round
    // is retained (its result honest about a possible side effect). The error is
    // reported and surfaced as a failed disposition.
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
        // Prompt plus the completed tool_call/tool_result round survive.
        try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
        try std.testing.expectEqualStrings("go", agent.items.items[0].message.text);
        try std.testing.expectEqualStrings("t1", agent.items.items[1].tool_call.call_id);
        try std.testing.expectEqualStrings("t1", agent.items.items[2].tool_result.call_id);
    }
    // A failed head on the first request commits nothing, so the turn rolls back
    // to its base and drops the prompt.
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

    // An exhausted 429 emits no stop event, but its head reported the spent
    // account: the gauge must show that, not the previous allowance.
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

    // A cancel interrupts the read before its stop, yet the head's allowance was
    // already captured.
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

    // A window states its reset against the response that carried it, so the
    // stamp must move only when a head states an allowance.
    agent.stats.quota_seen_ms = 0;
    var stated: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{
            .events = &end_turn_events,
            .quota = .{ .primary = .{
                .used_percent = 12,
                .window_minutes = 300,
                .reset_seconds = 3180,
            } },
        } },
    } };
    try agent.runWith(&stated, "go", &handler);
    const stamped = agent.stats.quota_seen_ms;
    try std.testing.expect(stamped > 0);

    // A head that states none keeps both the allowance and its stamp, so the
    // countdown keeps running down instead of starting again.
    var silent: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &end_turn_events } },
    } };
    try agent.runWith(&silent, "again", &handler);
    try std.testing.expectEqual(@as(f64, 12), agent.stats.quota.?.primary.?.used_percent);
    try std.testing.expectEqual(stamped, agent.stats.quota_seen_ms);
}

// The user wrote the message against a reply that was still streaming, so the
// finished reply can change what they want to send. A reply that asks for no
// tool ends the turn, and the queue holds the message for review.
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

// A round that asks for a tool keeps the turn alive on its own, so the steering
// of the user reaches the model before the model acts again.
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

    // The batch left the queue with the reply that committed it.
    const queued = try agent.steering.take();
    defer gpa.free(queued);
    try std.testing.expectEqual(@as(usize, 0), queued.len);
}

// A minimal tool source for whole-turn tests: "write" mutates, everything else
// reads, and every call returns a fixed success result. Unlike `probe` it reads
// no scheduling log, so it runs under any backing io.
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

// A tool source whose every call is a mutation that raises and returns no
// result. It exercises the conservative unfinished-call result retention path.
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

/// A read-only pair that proves tool errors and pending scheduling state remain distinct.
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
    // A failed allocation before the placeholder run is committed must leave
    // no tool announced and no slot appended.
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

    // The result is moved into history before the presentation callback runs,
    // so a callback failure cannot leave provider-visible history dishonest.
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
        // The commit of the round publishes the gauges before any dispatch.
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
    // The slot stays committed with its honest unfinished-call result and no callback.
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

    // Round 1 runs a tool. Round 2's request is canceled mid-stream.
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    // Prompt + tool_call + its real result survive at the checkpoint.
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

    // The read is canceled before any terminal `.stop`, but the stream had
    // already accumulated the prompt's usage, which the provider bills.
    var fetch: ScriptedFetch = .{ .attempts = &.{.{ .stream = .{
        .events = &.{},
        .terminal_error = error.Canceled,
        .usage_so_far = .{ .input = 1_000_000, .cache_read = 200_000 },
    } }} };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    // The billed prompt is recorded, and the cache-rate gauge reflects it.
    try std.testing.expect(agent.stats.cost > 0);
    try std.testing.expectEqual(@as(u64, 1_000_000), agent.stats.cache_usage.input);
    try std.testing.expectEqual(@as(u64, 200_000), agent.stats.cache_usage.cache_read);
}

test "a cancel before any usage frame leaves the cache-rate gauge intact" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A prior request's usage backs the cache-rate gauge.
    agent.stats.cache_usage = .{ .input = 42 };
    // A cancel before the stream reports any usage must not fold a zero reading
    // in and reset that gauge.
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } }},
    };
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

    // The stream reaches its terminal `.stop` and books usage once, but the
    // cancel lands during the usage callback that follows it. The partial fold
    // must not re-book the same usage, even though usage-so-far now equals it.
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
    // Recorded exactly once: the model prices 1M input at $3, so 1000 input
    // is $0.003.
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 1000), agent.stats.cache_usage.input);
}

test "a completed round is retained when a later steered reply is canceled" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Round 1 asks for a tool, which keeps the turn alive and folds the steering
    // in. Round 2 is canceled before it commits.
    try agent.steering.push("steer");
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &tool_round_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    // The completed tool round survives. The canceled steer round is dropped.
    try std.testing.expectEqual(@as(usize, 3), agent.items.items.len);
    try std.testing.expectEqualStrings("go", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("t1", agent.items.items[1].tool_call.call_id);
    try std.testing.expectEqualStrings("t1", agent.items.items[2].tool_result.call_id);
    // The steer was consumed but not committed, so it returns to the queue.
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
    // The steer batch is consumed in round 1 and committed by round 2's reply.
    try std.testing.expectEqual(@as(usize, 1), outcome.receipt.steering_committed_count);
    try std.testing.expectEqual(@as(usize, 5), outcome.receipt.history_end);
    try std.testing.expect(!outcome.receipt.truncated);
}
