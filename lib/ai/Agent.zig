//! Drives one user turn to completion. It appends the message, streams the
//! reply, runs the requested tools, and feeds the results back. It repeats
//! until the model asks for no more tools. Owns the conversation history.
//! Talks to the model through a neutral `provider.Client` and delegates
//! presentation to a handler.

const std = @import("std");

const llm = @import("llm.zig");
const models = @import("models.zig");
const net = @import("net.zig");
const provider = @import("provider.zig");
const Steering = @import("Steering.zig");
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
    "The tool stopped before Pith recorded a result. " ++
    "Pith does not know if the tool changed the system.";

/// The distinct models one session breaks its cost down by. An overflow drops
/// only the per-model detail, never the cumulative totals.
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
/// Bounds the bash tool's output window and runtime, handed to every tool call.
bash: tool.Context.Bash,
/// What the `describe_config` tool returns. The host owns the text and keeps it
/// alive for the session. An empty document means the host exposes no config.
config_document: []const u8,
/// The path-triggered skill rules, handed to every tool call. The host owns the
/// guard and keeps it alive for the session. Null means the host applies no
/// rule. The loaded skills belong to the conversation, so a reset forgets them.
skill_guard: ?*tool.SkillGuard,
items: std.ArrayList(llm.Item),
stats: Stats,
/// Steering messages the user submitted mid-turn, drained into the running turn
/// at each round boundary. Thread-safe: the UI thread pushes, and the worker takes.
steering: Steering,
/// The local policy for the stale-prompt-cache warning.
cache: CachePolicy,
/// The stable per-conversation prompt-cache routing key (used by OpenAI). Every
/// turn shares it until a deliberate reset rotates it.
cache_key: [32]u8,
/// The local cache evidence of this conversation, per account-model pair. Each
/// timestamp marks request dispatch, because the cache lookup happens before
/// response generation.
cache_evidence: CacheEvidence,

/// The newest possible touch of each cache the conversation used, plus the
/// model expected to serve the next request. The provider isolates caches per
/// account, a model change breaks the cache, and the resolved effort renders
/// into the request bytes, so the account-model-effort triple is the real key.
/// Bounded like `Stats.by_model`, so recording never allocates. A full table
/// drops a new triple, which then reads as a cold cache and warns: the cheap
/// failure direction.
const CacheEvidence = struct {
    entries: [entries_max]Entry = undefined,
    entry_count: usize = 0,
    /// The model that served the last reply, or empty for the active model. A
    /// provider-side fallback holds for a conversation, so the last server is
    /// the best prediction of the next one.
    expected_model: []const u8 = "",

    const entries_max = 16;

    /// One cache: its newest possible touch and the size of its reusable
    /// prefix. `model` points into the compiled model table. `effort` is the
    /// resolved wire form, because two levels that fold onto one named level
    /// write identical request bytes and share one cache.
    const Entry = struct {
        account: llm.Account,
        model: []const u8,
        effort: models.Model.EffortMap.Resolution,
        retention_ms: u64,
        request_at: std.Io.Clock.Timestamp,
        prefix_tokens: u64,
    };

    fn indexOf(
        self: *const CacheEvidence,
        account: llm.Account,
        model_name: []const u8,
        effort: models.Model.EffortMap.Resolution,
    ) ?usize {
        for (self.entries[0..self.entry_count], 0..) |*entry, index| {
            if (entry.account == account and std.mem.eql(u8, entry.model, model_name) and
                entry.effort.eql(effort))
            {
                return index;
            }
        }
        return null;
    }

    /// Record or update one triple. A full table drops the new triple.
    fn touch(self: *CacheEvidence, entry: Entry) void {
        if (self.indexOf(entry.account, entry.model, entry.effort)) |index| {
            self.entries[index] = entry;
            return;
        }
        if (self.entry_count == self.entries.len) return;
        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
    }

    /// Drop every entry of one account, for a credential replacement.
    fn dropAccount(self: *CacheEvidence, account: llm.Account) void {
        var retained_count: usize = 0;
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.account == account) continue;
            self.entries[retained_count] = entry;
            retained_count += 1;
        }
        self.entry_count = retained_count;
    }

    fn clear(self: *CacheEvidence) void {
        self.entry_count = 0;
        self.expected_model = "";
    }

    /// The newest entry of one account. The history is shared across the
    /// models of a conversation, so any entry's prefix approximates a cold
    /// model's rewrite size, and the newest is the closest.
    fn newestOf(self: *const CacheEvidence, account: llm.Account) ?*const Entry {
        var newest: ?*const Entry = null;
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.account != account) continue;
            const current = newest orelse {
                newest = entry;
                continue;
            };
            if (entry.request_at.raw.toNanoseconds() > current.request_at.raw.toNanoseconds())
                newest = entry;
        }
        return newest;
    }
};

/// The estimated cost effect when the next request probably reads no cache.
/// The cost covers only the reusable prefix, priced at the active model's
/// public API rates, which is the worst case among the candidate servers.
pub const CacheRisk = struct {
    retention_ms: u64,
    cost_extra: f64,
    cause: Cause,

    /// Why the next request probably reads no cache: the expected cache passed
    /// its retention window, or the expected model holds no cache in this
    /// conversation (after `/model` to a model the conversation has not used).
    pub const Cause = enum { stale, cold };
};

/// The local policy for the stale-prompt-cache warning. The host patches it from
/// its configuration. Nothing here reaches the wire, because the provider owns
/// the real retention.
pub const CachePolicy = struct {
    /// The retention that every Anthropic model uses in place of its compiled
    /// value. Null keeps the compiled value, and 0 turns the warning off.
    anthropic_retention_ms: ?u64 = null,
    /// The same override for every OpenAI model.
    openai_retention_ms: ?u64 = null,
    /// The smallest estimated extra cost that arms the warning. A cheaper risk
    /// starts its turn with no warning. Zero warns about every risk.
    warning_min_cost: f64 = 0,

    /// The retention this policy applies to `model` under `account`: the
    /// configured override of that vendor, or the model's compiled value.
    pub fn retentionMs(
        self: *const CachePolicy,
        account: llm.Account,
        model: *const models.Model,
    ) ?u64 {
        const configured = switch (account.provider()) {
            .anthropic => self.anthropic_retention_ms,
            .openai => self.openai_retention_ms,
        };
        return configured orelse model.cache_retention_ms;
    }
};

/// The cumulative session cost and cache savings, plus the last message's usage
/// and the latest subscription allowance for the gauges. Each message is priced
/// against the model that produced it, so the totals stay correct across a
/// mid-session `/model` switch. A plain value type: it copies whole across the
/// UI channel.
pub const Stats = struct {
    cost: f64 = 0,
    saved: f64 = 0,
    last: llm.Usage = .{},
    /// The active subscription account's remaining allowance, adopted from each
    /// response head that carries one. This includes a head whose stream then
    /// errors or is canceled, so an exhausted 429 still updates it. A head that
    /// omits one leaves it unchanged. The value is null until a head reports one.
    /// An account switch clears it. API-key accounts report none.
    quota: ?llm.Quota = null,
    by_model: [by_model_max]ByModel = [_]ByModel{.{}} ** by_model_max,
    model_count: usize = 0,

    /// One model's session totals. `name` points into the compiled model table
    /// (static lifetime).
    pub const ByModel = struct {
        name: []const u8 = "",
        cost: f64 = 0,
        saved: f64 = 0,
        usage: llm.Usage = .{},
    };

    /// Attribute one message to `name` and open a bucket on first appearance.
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

/// A reply that another model served than the request named. A provider can
/// switch a flagged request to a fallback model, so the handler reports the
/// switch instead of passing the reply off as the requested model's. The named
/// fields keep the two confusable names apart at the call site. Both slices
/// stay valid only for the duration of the callback.
pub const ModelMismatch = struct {
    requested: []const u8,
    served: []const u8,
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
        model: models.Model,
        system: []const u8,
        retry: net.Retry,
        effort: llm.Effort = .none,
        bash: tool.Context.Bash = .{},
        config_document: []const u8 = "",
        skill_guard: ?*tool.SkillGuard = null,
        cache: CachePolicy = .{},
    },
) Agent {
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .model = options.model,
        .system = options.system,
        .effort = options.effort,
        .retry = options.retry,
        .bash = options.bash,
        .config_document = options.config_document,
        .skill_guard = options.skill_guard,
        .items = .empty,
        .stats = .{},
        .steering = Steering.init(gpa, io),
        .cache = options.cache,
        .cache_key = generateCacheKey(io),
        .cache_evidence = .{},
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
    self.steering.clear();
    self.cache_key = generateCacheKey(self.io);
    self.cache_evidence.clear();
}

/// Switch the account and the model together, effective on the next turn. The
/// client carries both the transport and the reasoning-replay account, so the
/// pair is one atomic step. A model is never paired with a foreign vendor's
/// client. History is untouched. The new account drops reasoning it did not
/// produce.
pub fn switchTo(self: *Agent, client: provider.Client, model: models.Model) void {
    const account_changed = if (self.client) |active|
        active.account() != client.account()
    else
        true;
    self.client = client;
    self.model = model;
    // An allowance belongs to the account whose response reported it. Session
    // totals span account switches, but this point-in-time gauge must not.
    if (account_changed) self.stats.quota = null;
    // The cache entries stay: they key on the account-model pair, a switch
    // invalidates none of them on the provider, and a switch back within
    // retention meets a warm cache. Only the serving expectation resets,
    // because it belonged to the previous pairing.
    self.cache_evidence.expected_model = "";
}

/// Drop the active account and leave the agent signed out. `model` is kept as
/// the last-shown value. The account-specific allowance and cache evidence are
/// forgotten.
pub fn signOut(self: *Agent) void {
    self.client = null;
    self.stats.quota = null;
    self.cache_evidence.clear();
}

/// Forget everything bound to the provider principal behind `account`: its
/// replay proofs, its cache evidence, and its allowance gauge. A credential
/// replacement can put another principal in the same account slot, and none of
/// this state crosses that boundary. The account itself stays authenticated,
/// so a caller that drops the account calls `signOut` or `switchTo` as well.
pub fn dropAccountEvidence(self: *Agent, account: llm.Account) void {
    self.dropReasoning(account);
    self.dropCacheEvidence(account);
    // The gauge holds what the last response of the active account reported,
    // so only that account can own it. The serving expectation came from the
    // active account's replies too, so a replaced active principal takes it.
    const client = self.client orelse return;
    if (client.account() == account) {
        self.stats.quota = null;
        self.cache_evidence.expected_model = "";
    }
}

/// Drop cache evidence for an account whose credential changed. A credential
/// can now identify a different provider principal with an isolated cache.
fn dropCacheEvidence(self: *Agent, account: llm.Account) void {
    self.cache_evidence.dropAccount(account);
}

/// Remove replay proofs produced by one account slot. A successful credential
/// replacement calls this before that slot can represent another principal.
fn dropReasoning(self: *Agent, account: llm.Account) void {
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
}

/// Switch the reasoning-effort level. It takes effect on the next turn.
pub fn setEffort(self: *Agent, effort: llm.Effort) void {
    // The entries stay: the resolved effort is part of the cache key, so a
    // change reads as a cold cache and a change back within retention meets
    // the old warm one.
    self.effort = effort;
}

/// Estimate the cache rewrite risk for an idle submission. Null means there is
/// no committed context, no matching cache evidence past its retention, or a
/// cost under the policy's floor.
pub fn cacheRisk(self: *const Agent) ?CacheRisk {
    const now = std.Io.Clock.Timestamp.now(self.io, .boot);
    return self.cacheRiskAt(&now);
}

fn cacheRiskAt(self: *const Agent, now: *const std.Io.Clock.Timestamp) ?CacheRisk {
    if (self.items.items.len == 0) return null;
    const client = self.client orelse return null;
    const account = client.account();
    const expected = self.expectedModel();
    // The policy can turn the warning off for a vendor, and a model without a
    // stated retention cannot be judged. The expected model is the one whose
    // cache the check judges, so it resolves the policy too.
    const policy_retention_ms = self.cache.retentionMs(account, &expected) orelse return null;
    if (policy_retention_ms == 0) return null;
    if (now.clock != .boot) return null;
    const evidence = &self.cache_evidence;
    const effort = expected.effort.resolve(self.effort);
    const index = evidence.indexOf(account, expected.name, effort) orelse {
        // The expected model holds no cache under the active effort, so the
        // next request probably rewrites the whole history: the case after
        // `/model` or `/effort` to a pairing the conversation has not used.
        // The newest entry of the account sizes the estimate, because the
        // history is shared. A conversation with no entry at all has no size
        // and nothing to lose.
        const newest = evidence.newestOf(account) orelse return null;
        return self.riskOverPrefix(newest.prefix_tokens, policy_retention_ms, .cold);
    };
    const entry = &evidence.entries[index];
    if (entry.request_at.clock != .boot) return null;
    const elapsed_ns = entry.request_at.durationTo(now.*).raw.toNanoseconds();
    const retention_ns = @as(i96, @intCast(entry.retention_ms)) * std.time.ns_per_ms;
    if (elapsed_ns < retention_ns) return null;
    return self.riskOverPrefix(entry.prefix_tokens, entry.retention_ms, .stale);
}

/// The rewrite risk over one prefix, priced at the active model's rates and
/// held to the policy floor. Null on an empty prefix or a cost under the floor.
fn riskOverPrefix(
    self: *const Agent,
    prefix_tokens: u64,
    retention_ms: u64,
    cause: CacheRisk.Cause,
) ?CacheRisk {
    if (prefix_tokens == 0) return null;
    const fresh = self.model.cost(&.{ .cache_read = prefix_tokens });
    const stale = self.model.cost(&.{ .cache_write = prefix_tokens });
    const cost_extra = @max(0, stale - fresh);
    // A rewrite under the floor is not worth an interruption, so the turn
    // starts without one. The default floor of zero warns about every risk.
    if (cost_extra < self.cache.warning_min_cost) return null;
    return .{ .retention_ms = retention_ms, .cost_extra = cost_extra, .cause = cause };
}

/// The model expected to serve the next request: the one that served the last
/// reply, or the active model when no reply arrived since the last switch. The
/// table entry resolves the active effort into the wire form the cache keys on.
fn expectedModel(self: *const Agent) models.Model {
    const expected_name = self.cache_evidence.expected_model;
    if (expected_name.len == 0) return self.model;
    const client = self.client orelse return self.model;
    return models.get(client.account().provider(), expected_name) orelse self.model;
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
        if (!ran_tools) {
            self.advanceCheckpoint(turn);
            notifyCheckpoint(handler);
        }
        // Send every skill file that this round asked for, before the steering
        // of the user. A tool met a file that a rule guards, so the model needs
        // the rules of that file for whatever it does next.
        const loaded = try self.drainSkills(turn, handler);
        // Fold mid-turn steering in before the next round. With no tools asked,
        // a steering message keeps the turn alive and does not end it. A skill
        // file keeps it alive the same way, so the rules reach the model even
        // when the reply asked for nothing more.
        const steered = try self.drainSteering(turn, handler);
        if (!ran_tools and !steered and !loaded) return;
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

/// Advance the checkpoint to commit the latest reply (and any reserved
/// tool-result slots). The same advance commits the steering batch that preceded it.
fn advanceCheckpoint(self: *Agent, turn: *TurnState) void {
    turn.checkpoint = self.items.items.len;
    if (turn.pending_steering) |batch| {
        turn.steering_committed_count += batch.len;
        freeSteeringBatch(self.gpa, batch);
        turn.pending_steering = null;
    }
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
/// return it to the queue. A failed delivery returns it at once. Returns whether
/// anything was delivered.
fn drainSteering(self: *Agent, turn: *TurnState, handler: anytype) !bool {
    var pending = try self.steering.take();
    if (pending.len == 0) {
        self.gpa.free(pending);
        return false;
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
    return true;
}

/// Stream one assistant reply and retry transient failures. Only whole
/// requests are safe to retry, so a failed attempt's partial reply is discarded
/// (history untouched). `handler.onStreamReset` clears partial output first.
/// Returns the reply's items (already appended to history). An API error is
/// retried when its head or streamed event marks it transient and the retry
/// policy allows another try (see `net.Retry.allows`). An exhausted or permanent
/// one is reported through `handler.onError` and surfaced as `error.ApiError`,
/// which rolls the turn back to its latest checkpoint.
///
/// A head that rejects the credential takes one renewal and one repeat outside
/// that policy, because another Pith instance can have rotated the token this
/// one holds. A renewal that changes nothing reports the failure as it stands.
fn fetchReply(
    self: *Agent,
    fetch: anytype,
    turn: *TurnState,
    handler: anytype,
) ![]const llm.Item {
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
    var renewed = false;
    while (true) : (attempt += 1) {
        if (attempt > 1)
            try presentation(&turn.presentation_closed, handler.onStreamReset());
        const request_at = std.Io.Clock.Timestamp.now(self.io, .boot);
        var stream: @TypeOf(fetch.*).Stream = undefined;
        fetch.send(&stream, &request) catch |err| {
            const failure: net.Retry.Failure = .{ .attempt = attempt };
            if (retryableError(err) and self.retry.allows(failure)) {
                try self.backoff(failure);
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
        // allowance.
        if (stream.quotaSoFar()) |quota| self.stats.quota = quota;

        if (!stream.ok()) {
            // The provider rejected the credential. Another instance can have
            // rotated the token this one still holds, so renew it once and
            // repeat the request. Nothing streamed yet, so the repeat loses no
            // output.
            if (!renewed and stream.unauthorized()) {
                renewed = true;
                if (try fetch.renewCredential()) continue;
            }
            const failure: net.Retry.Failure = .{
                .attempt = attempt,
                .suggested_ms = stream.retryAfterMs() orelse 0,
            };
            if (stream.retryable() and self.retry.allows(failure)) {
                try self.backoff(failure);
                continue;
            }
            try presentation(&turn.presentation_closed, handler.onError(stream.errorText()));
            return error.ApiError;
        }
        // The provider accepted this attempt, so its cache lookup already
        // refreshed the real retention window. Anchor the evidence now, not at
        // usage receipt, so a canceled or failed attempt cannot leave a stale
        // anchor and a premature warning.
        self.refreshCacheAnchor(&request_at);
        var usage_recorded = false;
        const reply = self.readReplyWith(
            &model,
            &stream,
            turn,
            &usage_recorded,
            &request_at,
            handler,
        ) catch |err| switch (err) {
            error.ApiError => {
                self.recordUsageSoFar(&model, &stream, &usage_recorded, &request_at);
                const failure: net.Retry.Failure = .{
                    .attempt = attempt,
                    .suggested_ms = stream.retryAfterMs() orelse 0,
                };
                if (stream.retryable() and self.retry.allows(failure)) {
                    try self.backoff(failure);
                    continue;
                }
                try presentation(&turn.presentation_closed, handler.onError(stream.errorText()));
                return error.ApiError;
            },
            error.Canceled => {
                // A cancel that interrupts the read before its terminal `.stop`
                // still records whatever usage the provider delivered so far.
                self.recordUsageSoFar(&model, &stream, &usage_recorded, &request_at);
                return err;
            },
            else => {
                self.recordUsageSoFar(&model, &stream, &usage_recorded, &request_at);
                const failure: net.Retry.Failure = .{ .attempt = attempt };
                if (retryableError(err) and self.retry.allows(failure)) {
                    try self.backoff(failure);
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
}

/// Fold one message's usage into the totals, priced with `model`. The model is
/// threaded from the request so billing cannot drift when `/model` changes
/// `self.model`.
fn recordUsage(self: *Agent, model: *const models.Model, usage: *const llm.Usage) void {
    const cost = model.cost(usage);
    const saved = model.savings(usage);
    self.stats.cost += cost;
    self.stats.saved += saved;
    self.stats.last = usage.*;
    self.stats.attribute(model.name, cost, saved, usage);
}

/// Record billing and the cache prefix from one provider-accepted request.
/// `model` is the model that served the reply, or the requested model on the
/// error paths where no served name arrived. The reply is direct evidence for
/// the serving model's cache: its cache buckets describe that cache, touched
/// at this request's dispatch. `request_at` is the dispatch time, not the
/// later response completion, because the cache lookup happens before response
/// generation.
fn recordRequestUsage(
    self: *Agent,
    model: *const models.Model,
    usage: *const llm.Usage,
    request_at: *const std.Io.Clock.Timestamp,
) void {
    self.recordUsage(model, usage);
    const account = if (self.client) |client| client.account() else return;
    // A model whose retention the policy turns off, or one that states none,
    // takes no warning, so it needs no entry.
    const retention_ms = self.cache.retentionMs(account, model) orelse return;
    if (retention_ms == 0) return;
    // Only the cache buckets become a cheap read on the next request. The
    // uncached input and the output form a new delta regardless of expiry.
    const prefix_tokens = usage.cache_read +| usage.cache_write;
    self.cache_evidence.touch(.{
        .account = account,
        .model = model.name,
        .effort = model.effort.resolve(self.effort),
        .retention_ms = retention_ms,
        .request_at = request_at.*,
        .prefix_tokens = prefix_tokens,
    });
}

/// The model that prices one reply: the requested one, or the table entry of
/// the model the response names as the one that served it. An unknown served
/// name fails the turn, because a price at rates Pith does not know corrupts
/// the ledger silently. The failed attempt still bills at the requested rates
/// through the usage-so-far path, so the spend is kept while the report names
/// the model Pith cannot price.
fn pricingModel(
    self: *Agent,
    requested: *const models.Model,
    served_name: []const u8,
    presentation_closed: *bool,
    handler: anytype,
) !models.Model {
    if (served_name.len == 0 or std.mem.eql(u8, served_name, requested.name))
        return requested.*;
    const account = self.client.?.account();
    if (models.get(account.provider(), served_name)) |served| return served;
    const text = try std.fmt.allocPrint(
        self.gpa,
        "Pith does not know the model \"{s}\" that served this reply, so Pith cannot price " ++
            "it. Use /model to pick another model.",
        .{served_name},
    );
    defer self.gpa.free(text);
    try presentation(presentation_closed, handler.onError(text));
    return error.UnknownServedModel;
}

/// Refresh the cache anchor of the model expected to serve an attempt the
/// provider accepted. The cache lookup happens before response generation, so
/// an accepted attempt refreshes the real retention window even when it later
/// fails, is canceled, or streams no usage frame. Without this refresh the
/// anchor goes stale and the next submit warns early. Evidence recorded later
/// by the same attempt overwrites this with the same timestamp.
fn refreshCacheAnchor(self: *Agent, request_at: *const std.Io.Clock.Timestamp) void {
    const client = self.client orelse return;
    const expected = self.expectedModel();
    const index = self.cache_evidence.indexOf(
        client.account(),
        expected.name,
        expected.effort.resolve(self.effort),
    ) orelse return;
    self.cache_evidence.entries[index].request_at = request_at.*;
}

/// Record a stream's nonzero running usage unless its terminal event already did.
fn recordUsageSoFar(
    self: *Agent,
    model: *const models.Model,
    stream: anytype,
    usage_recorded: *bool,
    request_at: *const std.Io.Clock.Timestamp,
) void {
    if (usage_recorded.*) return;
    const usage = stream.usageSoFar();
    if (std.meta.eql(usage, llm.Usage{})) return;
    self.recordRequestUsage(model, &usage, request_at);
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
    model: *const models.Model,
    stream: anytype,
    handler: anytype,
) ![]const llm.Item {
    var turn: TurnState = .{ .base = self.items.items.len, .checkpoint = self.items.items.len };
    var usage_recorded = false;
    const request_at = std.Io.Clock.Timestamp.now(self.io, .boot);
    return self.readReplyWith(model, stream, &turn, &usage_recorded, &request_at, handler);
}

fn readReplyWith(
    self: *Agent,
    model: *const models.Model,
    stream: anytype,
    turn: *TurnState,
    usage_recorded: *bool,
    request_at: *const std.Io.Clock.Timestamp,
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
    // fallback bills at the fallback's rates. An unknown served model fails the
    // turn instead of pricing at rates Pith cannot know.
    const priced_model = try self.pricingModel(model, stop.model, presentation_closed, handler);
    // Terminal usage is billable even when replay validation rejects the reply
    // and the request is retried.
    self.recordRequestUsage(&priced_model, &stop.usage, request_at);
    // The server that answered last is the best prediction of the next one,
    // because a provider-side fallback holds for a conversation. Only a reply
    // states its server, so the error paths leave the expectation alone.
    self.cache_evidence.expected_model = priced_model.name;
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
    if (stop.model.len != 0 and !std.mem.eql(u8, stop.model, model.name))
        try presentation(presentation_closed, handler.onModelMismatch(.{
            .requested = model.name,
            .served = stop.model,
        }));

    const start = self.items.items.len;
    try self.items.appendSlice(gpa, reply_items.items);
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
    self.advanceCheckpoint(turn);
    notifyCheckpoint(handler);

    const context: tool.Context = .{
        .gpa = self.gpa,
        .io = self.io,
        .bash = self.bash,
        .config_document = self.config_document,
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
    const model = agent.model;
    const cache_key = agent.cache_key;
    agent.effort = .high;
    try agent.appendUser("old prompt");
    const usage: llm.Usage = .{ .input = 1000, .output = 200, .cache_write = 500 };
    const request_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_ms),
        .clock = .boot,
    };
    agent.recordRequestUsage(&agent.model, &usage, &request_at);
    try std.testing.expect(agent.stats.model_count == 1);
    try std.testing.expectEqual(@as(usize, 1), agent.cache_evidence.entry_count);
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
    try std.testing.expectEqual(@as(usize, 0), agent.cache_evidence.entry_count);
    try std.testing.expectEqual(account, agent.client.?.account());
    try std.testing.expectEqualStrings(model.name, agent.model.name);
    try std.testing.expectEqual(llm.Effort.high, agent.effort);
}

test "an account change or sign-out clears the previous account's quota" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const same_account = agent.client.?;
    const sonnet = models.get(.anthropic, "claude-sonnet-4-6").?;
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
    const openai_model = models.get(.openai, "gpt-5.6-sol").?;
    agent.switchTo(openai_client, openai_model);
    try std.testing.expect(agent.stats.quota == null);

    agent.stats.quota = .{ .secondary = .{ .used_percent = 75, .window_minutes = 10080 } };
    agent.signOut();
    try std.testing.expect(agent.stats.quota == null);
}

test "cache risk follows the active provider retention and refresh time" {
    const gpa = std.testing.allocator;
    var anthropic_agent = scriptedAgent(gpa);
    defer anthropic_agent.deinit();
    try anthropic_agent.appendUser("committed context");

    const start: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
    const usage: llm.Usage = .{ .cache_read = 160_000, .cache_write = 40_000 };
    anthropic_agent.recordRequestUsage(&anthropic_agent.model, &usage, &start);

    const before_anthropic: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(5 * std.time.ns_per_min - 1),
        .clock = .boot,
    };
    try std.testing.expect(anthropic_agent.cacheRiskAt(&before_anthropic) == null);
    const at_anthropic: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(5 * std.time.ns_per_min),
        .clock = .boot,
    };
    const anthropic_risk = anthropic_agent.cacheRiskAt(&at_anthropic).?;
    try std.testing.expectEqual(@as(u64, 5 * std.time.ms_per_min), anthropic_risk.retention_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 1.15), anthropic_risk.cost_extra, 1e-9);

    const refreshed_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(4 * std.time.ns_per_min),
        .clock = .boot,
    };
    anthropic_agent.recordRequestUsage(&anthropic_agent.model, &usage, &refreshed_at);
    try std.testing.expect(anthropic_agent.cacheRiskAt(&at_anthropic) == null);
    const after_refresh: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(9 * std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expect(anthropic_agent.cacheRiskAt(&after_refresh) != null);

    var openai_agent = openaiScriptedAgent(gpa);
    defer openai_agent.deinit();
    try openai_agent.appendUser("committed context");
    openai_agent.recordRequestUsage(&openai_agent.model, &usage, &start);
    try std.testing.expect(openai_agent.cacheRiskAt(&at_anthropic) == null);
    const at_openai: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(30 * std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expect(openai_agent.cacheRiskAt(&at_openai) != null);
}

test "the cache policy overrides one vendor's retention and floors the warning" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    agent.cache = .{ .anthropic_retention_ms = std.time.ms_per_min };
    try agent.appendUser("committed context");

    const start: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
    const usage: llm.Usage = .{ .cache_read = 160_000, .cache_write = 40_000 };
    const at_minute: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_min),
        .clock = .boot,
    };

    // The override replaces the compiled 5 minutes of the model, so the same
    // evidence goes stale four minutes earlier.
    agent.recordRequestUsage(&agent.model, &usage, &start);
    const risk = agent.cacheRiskAt(&at_minute).?;
    try std.testing.expectEqual(@as(u64, std.time.ms_per_min), risk.retention_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 1.15), risk.cost_extra, 1e-9);

    // An override of the other vendor leaves this model on its compiled value.
    agent.cache = .{ .openai_retention_ms = std.time.ms_per_min };
    agent.recordRequestUsage(&agent.model, &usage, &start);
    try std.testing.expect(agent.cacheRiskAt(&at_minute) == null);

    // A floor above the estimate starts the turn without a warning. The
    // estimate itself still arms one.
    agent.cache = .{
        .anthropic_retention_ms = std.time.ms_per_min,
        .warning_min_cost = 1.2,
    };
    agent.recordRequestUsage(&agent.model, &usage, &start);
    try std.testing.expect(agent.cacheRiskAt(&at_minute) == null);
    agent.cache.warning_min_cost = 1.15;
    try std.testing.expect(agent.cacheRiskAt(&at_minute) != null);

    // A retention of 0 turns the warning off, however long the wait was.
    agent.cache = .{ .anthropic_retention_ms = 0 };
    agent.recordRequestUsage(&agent.model, &usage, &start);
    const at_hour: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_hour),
        .clock = .boot,
    };
    try std.testing.expect(agent.cacheRiskAt(&at_hour) == null);
}

test "cache risk needs matching setup, effort, and a reusable prefix" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    const start: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
    const stale_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(5 * std.time.ns_per_min),
        .clock = .boot,
    };

    agent.recordRequestUsage(&agent.model, &.{ .cache_read = 1000 }, &start);
    try std.testing.expect(agent.cacheRiskAt(&stale_at) == null);
    try agent.appendUser("committed context");
    agent.recordRequestUsage(&agent.model, &.{ .input = 1000 }, &start);
    try std.testing.expect(agent.cacheRiskAt(&stale_at) == null);

    agent.recordRequestUsage(&agent.model, &.{ .cache_read = 1000 }, &start);
    try std.testing.expect(agent.cacheRiskAt(&stale_at) != null);
    // The resolved effort is part of the cache key: a change reads as a cold
    // cache at once, and a change back within retention meets the old warm one.
    const warm_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expect(agent.cacheRiskAt(&warm_at) == null);
    agent.setEffort(.high);
    try std.testing.expect(agent.cache_evidence.entry_count != 0);
    try std.testing.expectEqual(
        CacheRisk.Cause.cold,
        agent.cacheRiskAt(&warm_at).?.cause,
    );
    agent.setEffort(.none);
    try std.testing.expect(agent.cacheRiskAt(&warm_at) == null);

    const client = agent.client.?;
    agent.switchTo(client, models.get(.anthropic, "claude-sonnet-4-6").?);
    // A model switch keeps the entries: the new model's cold cache warns at
    // once, and a switch back can meet the old model's warm cache.
    try std.testing.expect(agent.cache_evidence.entry_count != 0);
    try std.testing.expectEqual(
        CacheRisk.Cause.cold,
        agent.cacheRiskAt(&stale_at).?.cause,
    );

    agent.recordRequestUsage(&agent.model, &.{ .cache_write = 1000 }, &start);
    agent.dropCacheEvidence(.anthropic_subscription);
    try std.testing.expect(agent.cache_evidence.entry_count == 0);

    agent.recordRequestUsage(&agent.model, &.{ .cache_write = 1000 }, &start);
    agent.client = null;
    // A signed-out record books the money and leaves the evidence alone, and
    // the consult returns null without a client either way.
    agent.recordRequestUsage(&agent.model, &.{ .cache_write = 1000 }, &start);
    try std.testing.expect(agent.cacheRiskAt(&stale_at) == null);
}

// A model switch meets per-model reality: the new model holds no cache for
// this conversation, so the first submit warns at once, and a switch back
// within retention meets the old model's still-warm cache and stays silent.
test "a model switch warns on a cold cache and not on a warm one" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    try agent.appendUser("committed context");
    const start: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
    const usage: llm.Usage = .{ .cache_read = 160_000, .cache_write = 40_000 };
    agent.recordRequestUsage(&agent.model, &usage, &start);

    // Warm on the same model: silence.
    const soon: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expect(agent.cacheRiskAt(&soon) == null);

    // `/model` to a model this conversation has not used: its cache is cold,
    // so the warning fires at once, sized by the shared history and priced at
    // the new model's rates: (3.75 - 0.3) * 0.2 million tokens.
    const client = agent.client.?;
    agent.switchTo(client, models.get(.anthropic, "claude-sonnet-4-6").?);
    const cold_risk = agent.cacheRiskAt(&soon).?;
    try std.testing.expectEqual(CacheRisk.Cause.cold, cold_risk.cause);
    try std.testing.expectApproxEqAbs(@as(f64, 0.69), cold_risk.cost_extra, 1e-9);

    // The switch back within retention meets the old model's warm cache.
    agent.switchTo(client, models.get(.anthropic, "claude-opus-4-8").?);
    try std.testing.expect(agent.cacheRiskAt(&soon) == null);
    // Past retention the timing rule warns as always.
    const late: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(10 * std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expectEqual(
        CacheRisk.Cause.stale,
        agent.cacheRiskAt(&late).?.cause,
    );
}

/// A cache-only clock over a real vtable. This test calls only `now`, because
/// each copied backend function expects the backend's original userdata.
const CacheClock = struct {
    vtable: std.Io.VTable,
    now_ns: i96,
    requested: ?std.Io.Clock = null,

    fn init(backend: std.Io, now_ns: i96) CacheClock {
        var vtable = backend.vtable.*;
        vtable.now = now;
        return .{ .vtable = vtable, .now_ns = now_ns };
    }

    fn io(self: *CacheClock) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const self: *CacheClock = @ptrCast(@alignCast(userdata));
        self.requested = clock;
        return .fromNanoseconds(self.now_ns);
    }
};

test "cache expiry requests the monotonic boot clock" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    try agent.appendUser("committed context");
    const start: std.Io.Clock.Timestamp = .{ .raw = .zero, .clock = .boot };
    agent.recordRequestUsage(&agent.model, &.{ .cache_read = 1000 }, &start);

    var clock = CacheClock.init(std.testing.io, 5 * std.time.ns_per_min);
    agent.io = clock.io();
    try std.testing.expect(agent.cacheRisk() != null);
    try std.testing.expectEqual(std.Io.Clock.boot, clock.requested.?);
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
    try std.testing.expect(try agent.drainSteering(&turn, &handler));

    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(llm.Role.user, agent.items.items[0].message.role);
    try std.testing.expectEqualStrings("a\n\nb", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("a\n\nb", handler.text.items);
    try std.testing.expectEqual(@as(usize, 2), handler.count);
    // The delivered batch is consumed but retained until its following reply.
    try std.testing.expect(turn.pending_steering != null);
    try std.testing.expectEqual(@as(usize, 0), turn.steering_committed_count);

    try std.testing.expect(!try agent.drainSteering(&turn, &handler));
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
    try std.testing.expect(try agent.drainSteering(&turn, &handler));

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
    errors: std.ArrayList(u8) = .empty,
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
        _ = stats;
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
    stream.anthropic_subscription.frame_arena = .init(std.testing.allocator);
    stream.anthropic_subscription.stop_reason = .none;
    stream.anthropic_subscription.terminal_rejection = null;
    stream.anthropic_subscription.open_block = null;
    stream.anthropic_subscription.reasoning = .none;
    stream.anthropic_subscription.block_text = .empty;
    stream.anthropic_subscription.block_proof = .empty;
    stream.anthropic_subscription.tool_call_id = .empty;
    stream.anthropic_subscription.tool_name = .empty;
    stream.anthropic_subscription.served_model = .empty;
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
    stream.openai_api.terminal_rejection = null;
    stream.openai_api.incomplete_message = false;
    stream.openai_api.reasoning = .none;
    stream.openai_api.summary_index = 0;
    stream.openai_api.completed_item_ids = .empty;
    stream.openai_api.call_item_id = .empty;
    stream.openai_api.served_model = .empty;
    stream.openai_api.usage = .{};
    stream.openai_api.quota = null;
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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
    _ = try agent.readReply(&agent.model, &fallback_stream, &handler);
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-sonnet-4-6\n",
        handler.model_mismatches.items,
    );

    const served_as_requested = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1 }, .model = "claude-opus-4-8" } },
    };
    var matching_stream: ScriptedStream = .{ .events = &served_as_requested };
    _ = try agent.readReply(&agent.model, &matching_stream, &handler);
    const served_unnamed = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = .{ .output = 1 } } },
    };
    var unnamed_stream: ScriptedStream = .{ .events = &served_unnamed };
    _ = try agent.readReply(&agent.model, &unnamed_stream, &handler);
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
        agent.readReply(&agent.model, &rejected_stream, &handler),
    );
    try std.testing.expectEqualStrings(
        "claude-opus-4-8 claude-sonnet-4-6\n",
        handler.model_mismatches.items,
    );
}

// The provider bills a switched request at the fallback's rates, so the ledger
// must price the reply at the model that served it and attribute the usage to
// that model's bucket. The reply is also direct evidence for the serving
// model's cache, and that model is the expected next server, so the warning
// stays silent while the fallback's cache is warm and fires past retention.
test "readReply prices a reply at the model that served it" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const usage: llm.Usage = .{ .input = 1_000_000, .output = 10_000, .cache_write = 100 };
    const events = [_]llm.Event{
        .{ .item = .{ .message = "done" } },
        .{ .stop = .{ .usage = usage, .model = "claude-sonnet-4-6" } },
    };
    var stream: ScriptedStream = .{ .events = &events };
    _ = try agent.readReply(&agent.model, &stream, &handler);

    const served = models.get(.anthropic, "claude-sonnet-4-6").?;
    try std.testing.expectEqual(served.cost(&usage), agent.stats.cost);
    try std.testing.expectEqual(served.savings(&usage), agent.stats.saved);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.stats.by_model[0].name);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.cache_evidence.entries[0].model);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.cache_evidence.expected_model);

    // The anchor moves to a known time first, because readReply stamped the
    // real clock.
    const anchored_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_ms),
        .clock = .boot,
    };
    agent.refreshCacheAnchor(&anchored_at);
    // Within retention the sticky fallback keeps its own cache warm: silence.
    const warm_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(4 * std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expect(agent.cacheRiskAt(&warm_at) == null);
    // Past retention every candidate cache is stale, so the warning fires.
    const probe_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(10 * std.time.ns_per_min),
        .clock = .boot,
    };
    try std.testing.expectEqual(
        CacheRisk.Cause.stale,
        agent.cacheRiskAt(&probe_at).?.cause,
    );
}

// The cache lookup happens before response generation, so an attempt the
// provider accepted refreshes the real retention window at its dispatch even
// when it streams no usage. The anchor must follow, or the next submit warns
// about a cache the provider just refreshed.
test "an accepted attempt refreshes the cache anchor without usage" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();

    const first_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(std.time.ns_per_ms),
        .clock = .boot,
    };
    agent.recordRequestUsage(&agent.model, &.{ .cache_write = 1000 }, &first_at);
    const later_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(4 * std.time.ns_per_min),
        .clock = .boot,
    };
    agent.refreshCacheAnchor(&later_at);
    try std.testing.expectEqual(later_at.raw, agent.cache_evidence.entries[0].request_at.raw);
    // The refreshed prefix stays warm past the old anchor's expiry.
    const probe_at: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(8 * std.time.ns_per_min),
        .clock = .boot,
    };
    try agent.appendUser("hi");
    try std.testing.expect(agent.cacheRiskAt(&probe_at) == null);

    // Without evidence there is nothing to anchor, so the refresh is a no-op.
    agent.cache_evidence.clear();
    agent.refreshCacheAnchor(&later_at);
    try std.testing.expectEqual(@as(usize, 0), agent.cache_evidence.entry_count);
}

// A price at rates Pith does not know corrupts the ledger silently, so an
// unknown served model fails the turn with a report that names it. The user
// adds support for the model instead of reading a wrong total.
test "readReply fails a reply that an unknown model served" {
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
    try std.testing.expectError(
        error.UnknownServedModel,
        agent.readReply(&agent.model, &stream, &handler),
    );
    try std.testing.expectEqualStrings(
        "Pith does not know the model \"claude-mythos-5\" that served this reply, " ++
            "so Pith cannot price it. Use /model to pick another model.",
        handler.errors.items,
    );
    // Nothing was priced, so the ledger holds no number the report contradicts.
    try std.testing.expectEqual(@as(usize, 0), handler.usage_count);
    try std.testing.expectEqual(@as(f64, 0), agent.stats.cost);
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
    const reply = try agent.readReply(&agent.model, &stream, &handler);

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
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 17), agent.stats.last.input);
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
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 23), agent.stats.last.output);
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
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(events.len, stream.index);
        try std.testing.expectEqual(@as(u64, 29), agent.stats.last.cache_read);
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
        agent.readReply(&agent.model, &stream, &handler),
    );
    try std.testing.expectEqual(@as(u64, 3), agent.stats.last.output);
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
    const reply = try agent.readReply(&agent.model, &stream, &handler);
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
    _ = try agent.readReply(&agent.model, &stream, &handler);
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
    _ = try agent.readReply(&agent.model, &stream, &handler);
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqualStrings("done", reply[0].message.text);
    try std.testing.expectEqual(@as(u64, 10), agent.stats.last.input);
    try std.testing.expectEqual(@as(u64, 4), agent.stats.last.output);
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
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 11), agent.stats.last.input);
        try std.testing.expectEqual(@as(u64, 7), agent.stats.last.output);
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
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 13), agent.stats.last.input);
        try std.testing.expectEqual(@as(u64, 5), agent.stats.last.output);
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
            agent.readReply(&agent.model, &stream, &handler),
        );
        try std.testing.expectEqual(@as(u64, 17), agent.stats.last.input);
        try std.testing.expectEqual(@as(u64, 3), agent.stats.last.output);
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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
            agent.readReply(&agent.model, &stream, &handler),
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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
    try std.testing.expectEqual(@as(u64, 5), agent.stats.last.output);
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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

    const reply = try agent.readReply(&agent.model, &stream, &handler);
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
    const reply = try agent.readReply(&agent.model, &stream, &handler);
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
    _ = try agent.readReply(&agent.model, &anthropic_stream, &handler);

    const openai_model = models.get(.openai, "gpt-5.6-sol").?;
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
    _ = try agent.readReply(&agent.model, &openai_stream, &handler);

    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    agent.dropReasoning(.anthropic_subscription);
    try std.testing.expectEqual(@as(usize, 1), agent.items.items.len);
    try std.testing.expectEqual(
        llm.Account.openai_api,
        std.meta.activeTag(agent.items.items[0].reasoning.replay),
    );
    agent.dropReasoning(.openai_api);
    try std.testing.expectEqual(@as(usize, 0), agent.items.items.len);
}

test "dropped account evidence takes the allowance of the active account only" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    const quota: llm.Quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };

    // The gauge belongs to the account whose response reported it, so another
    // account's replaced credential leaves it alone.
    agent.stats.quota = quota;
    agent.cache_evidence.touch(.{
        .account = .openai_api,
        .model = "gpt-5.6-sol",
        .effort = .{ .named = "xhigh" },
        .retention_ms = 300_000,
        .request_at = .{ .raw = .zero, .clock = .boot },
        .prefix_tokens = 1000,
    });
    agent.cache_evidence.touch(.{
        .account = .anthropic_subscription,
        .model = "claude-opus-4-8",
        .effort = .omitted,
        .retention_ms = 300_000,
        .request_at = .{ .raw = .zero, .clock = .boot },
        .prefix_tokens = 1000,
    });
    agent.cache_evidence.expected_model = "claude-opus-4-8";
    agent.dropAccountEvidence(.openai_api);
    try std.testing.expect(agent.stats.quota != null);
    // Only the replaced account's entries fall. The other account keeps its
    // evidence and its serving expectation, because its principal did not
    // change.
    try std.testing.expectEqual(@as(usize, 1), agent.cache_evidence.entry_count);
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.cache_evidence.entries[0].model);
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.cache_evidence.expected_model);

    // A replaced credential of the active account takes it, because the next
    // principal has its own allowance and its own serving history.
    agent.dropAccountEvidence(.anthropic_subscription);
    try std.testing.expect(agent.stats.quota == null);
    try std.testing.expectEqualStrings("", agent.cache_evidence.expected_model);

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
        const reply = try agent.readReply(&agent.model, &stream, &handler);
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
            agent.readReply(&agent.model, &stream, &handler),
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
        const reply = try agent.readReply(&agent.model, &stream, &handler);
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
            agent.readReply(&agent.model, &stream, &handler),
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
            agent.readReply(&agent.model, &stream, &handler),
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
            agent.readReply(&agent.model, &stream, &handler),
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
            agent.readReply(&agent.model, &stream, &handler),
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
            agent.readReply(&agent.model, &stream, &handler),
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

// A tool that meets a guarded file asks Pith for the skill. The round boundary
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
    try std.testing.expectEqual(@as(usize, 0), handler.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqual(@as(u64, 5000), log.slept_ms[0]);
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqual(@as(u64, 7), agent.stats.by_model[0].usage.input);
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

    // Without the hint the first backoff is backoff_ms_initial (500ms).
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

// Another Pith instance can refresh the credential this one holds, which
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

test "steering queued at the end of a turn keeps that turn alive" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    const second_events = [_]llm.Event{
        .{ .text = "more" },
        .{ .item = .{ .message = "more" } },
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
    // The billed prompt is recorded, and the last-request gauge reflects it.
    try std.testing.expect(agent.stats.cost > 0);
    try std.testing.expectEqual(@as(u64, 1_000_000), agent.stats.last.input);
    try std.testing.expectEqual(@as(u64, 200_000), agent.stats.last.cache_read);
}

test "a cancel before any usage frame leaves the last-request gauge intact" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // A prior request's usage backs the last-request gauge.
    agent.stats.last = .{ .input = 42 };
    // A cancel before the stream reports any usage must not fold a zero reading
    // in and reset that gauge.
    var fetch: ScriptedFetch = .{
        .attempts = &.{.{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } }},
    };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    try std.testing.expectEqual(@as(u64, 42), agent.stats.last.input);
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
    // Recorded exactly once: opus prices 1M input at $5, so 1000 input is $0.005.
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), agent.stats.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 1000), agent.stats.last.input);
}

test "a no-tool reply is retained when a later steered reply is canceled" {
    const gpa = std.testing.allocator;
    var agent = scriptedAgent(gpa);
    defer agent.deinit();
    var handler: CaptureHandler = .{ .gpa = gpa };
    defer handler.deinit();

    // Round 1 answers with no tools. A steering message keeps the turn alive.
    // Round 2 is canceled before it commits.
    try agent.steering.push("steer");
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &end_turn_events } },
        .{ .stream = .{ .events = &.{}, .terminal_error = error.Canceled } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .canceled);
    // The completed no-tool reply survives. The canceled steer round is dropped.
    try std.testing.expectEqual(@as(usize, 2), agent.items.items.len);
    try std.testing.expectEqualStrings("go", agent.items.items[0].message.text);
    try std.testing.expectEqualStrings("hi", agent.items.items[1].message.text);
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

    const second_events = [_]llm.Event{
        .{ .text = "more" },
        .{ .item = .{ .message = "more" } },
        .{ .stop = .{ .usage = .{} } },
    };
    try agent.steering.push("steer");
    var fetch: ScriptedFetch = .{ .attempts = &.{
        .{ .stream = .{ .events = &end_turn_events } },
        .{ .stream = .{ .events = &second_events } },
    } };
    const outcome = agent.runTurnWith(&fetch, fake_tools, "go", &handler);
    try std.testing.expect(std.meta.activeTag(outcome.disposition) == .completed);
    // The steer batch is consumed in round 1 and committed by round 2's reply.
    try std.testing.expectEqual(@as(usize, 1), outcome.receipt.steering_committed_count);
    try std.testing.expectEqual(@as(usize, 4), outcome.receipt.history_end);
    try std.testing.expect(!outcome.receipt.truncated);
}
