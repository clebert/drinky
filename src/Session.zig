//! The render consumer: the durable model the interface projects and the code
//! that applies events to it and paints. It owns the `Transcript`, the sole
//! transient notice, the interaction `mode` (prompt / streaming turn / picker /
//! read-only page), and the `editor`. It also owns the reconciling `view`, the
//! last laid-out dimensions, and consumer-side snapshots of usage, model, and
//! account. Everything here is io-, tty-, and agent-free. Producers hand
//! it `UiEvent`s and `App` drives its mutations. Tests can then drive the
//! render loop from a scripted event sequence without real io.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const layout = @import("layout.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");

const Session = @This();

/// The transcript shows this event when a turn committed a reply the provider
/// cut short, so a partial answer never reads as a complete one.
const truncated_event =
    "The response is incomplete. The model reached an output or context limit.";

gpa: std.mem.Allocator,
transcript: Transcript,
/// The sole transient notice. Its owned content never enters the transcript.
notice: ?ai.command.Outcome.Message,
editor: ui.Editor,
/// The primary-screen conversation renderer remains untouched while a page is open.
view: terminal.View,
/// A separate renderer for temporary content on the alternate screen.
page_view: terminal.View,
/// The current interaction. The editor is live while the session waits or
/// streams. A picker or full-window page replaces it.
mode: Mode,
columns: usize,
rows: usize,
/// The model changed since the last paint. The next tick repaints and clears it.
/// The event-appliers and lifecycle methods self-mark. `App` sets it directly
/// after it mutates a widget (the editor, the picker).
dirty: bool,
/// The consumer-owned copy of the agent's usage/cost. `.usage` events update
/// it, so the status gauge never reads `agent.stats` across the worker thread.
stats_shown: ai.Agent.Stats,
/// The consumer-owned copy of the active model. It updates after a command
/// runs, so `paint` needs no agent for the context-window and model-name gauges.
model_shown: ai.models.Model,
/// The consumer-owned copy of the reasoning-effort level for the status-line
/// indicator. It updates after a command runs.
effort_shown: ai.llm.Effort,
/// The active account. It mirrors the agent after a command runs. Null shows a
/// signed-out indicator. The model and effort are then stale placeholders.
account_shown: ?ai.llm.Account,
/// Steering submitted during a turn, in chronological order, as detached editor
/// drafts. Recall can then restore live placeholder markers. The plain queue is
/// a suffix of this list. Consumed drafts remain owned until the terminal
/// receipt either drops or restores them.
steering: std.ArrayList(ui.Editor.Draft),
/// Leading drafts hidden from the compact queue view because the worker has
/// taken them. A taken draft is consumed into the running turn, or in flight
/// after an Alt+Up take that did not return it. Consumption never destroys
/// their rich drafts, so a rolled-back batch remains recoverable. The terminal
/// receipt resolves them. Always at most `steering.items.len`.
steering_retained_count: usize,
/// Leading drafts the worker has reported as consumed (≤ `steering_retained_count`
/// and the source of it on consumption). The count is cumulative, so a delayed
/// consumed event does not double-count drafts an Alt+Up already hid.
steering_consumed_count: usize,
/// Borrowed compact `Queued message:` rows: each non-retained draft's collapsed
/// visible text. Each paint rebuilds them, so the tail gets a
/// `[]const []const u8` without a per-repaint allocation.
steering_view: std.ArrayList([]const u8),
/// The submitted prompt's rich draft, retained while a turn is live. A failed
/// or cancelled turn that committed nothing returns it to the editor. Every
/// other terminal frees it because the prompt belongs to committed history.
turn_origin: ?TurnOrigin,

const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
    viewing: ui.Page,
};

/// A streaming turn: the input-border activity tick and the running tool calls,
/// each shown as its own box in the live tail.
const Turn = struct {
    generation: u64,
    /// The last worker progress event applied for this generation.
    progress_sequence_applied: u64,
    /// The worker progress frontier that `transcript_checkpoint` mirrors.
    progress_sequence_checkpoint: u64,
    /// The transcript length after the newest applied event known to be committed.
    transcript_checkpoint: usize,
    activity_tick: u64,
    /// The motion tick observed at the latest accepted progress event.
    progress_tick_last: u64,
    tools: std.ArrayList(ActiveTool),
    /// `tools`' box text. Each frame rebuilds it, so the tail gets a
    /// `[]const []const u8` without a fresh allocation per repaint.
    box_view: std.ArrayList([]const u8),

    fn activity(self: *const Turn) ui.paint.Activity {
        return .{
            .motion_tick = self.activity_tick,
            .progress_age_ticks = self.activity_tick -% self.progress_tick_last,
        };
    }

    fn boxes(self: *Turn, gpa: std.mem.Allocator) ![]const []const u8 {
        self.box_view.clearRetainingCapacity();
        for (self.tools.items) |tool| try self.box_view.append(gpa, tool.box);
        return self.box_view.items;
    }
};

/// One running tool call: its blue box shows in the live tail. `name` matches
/// the result to it. `input_json` labels that result. `box` is the box text
/// (`name input_json`). All owned, freed on completion.
const ActiveTool = struct { name: []const u8, input_json: []const u8, box: []const u8 };

const Picking = struct {
    picker: ui.Picker,
    /// The selection handler. Picker confirmation calls it with the chosen row.
    select: *const fn (*ai.command.Context, usize) anyerror!ai.command.Outcome,
    /// The borrowed sentence that identifies the canceled selection.
    cancellation_message: []const u8,
};

/// The retained prompt draft for a live turn.
const TurnOrigin = struct {
    prompt: ui.Editor.Draft,
};

/// A turn worker's message to the render consumer, tagged with the generation it
/// belongs to. Every payload owns its bytes until the consumer frees it.
pub const TurnEvent = struct {
    generation: u64,
    /// Monotonic within one worker. Only direct model tests that do not
    /// exercise the cross-thread commit frontier use zero.
    progress_sequence: u64 = 0,
    /// The worker committed events through this sequence before it sent this event.
    progress_sequence_committed: u64 = 0,
    payload: Payload,

    pub const Payload = union(enum) {
        text: []u8,
        thinking: []u8,
        tool_start: Tool,
        tool_result: ToolResult,
        usage: ai.Agent.Stats,
        /// A retry is about to re-stream the reply: drop the partial text shown so
        /// far so the retried attempt starts clean.
        stream_reset,
        /// The worker folded `count` queued steering messages into the running
        /// turn as one combined message: show it, hide those rows from the queue
        /// view, and retain their rich drafts until the receipt resolves them.
        steering_consumed: SteeringConsumed,
        /// Payload-free wakeup: the authoritative worker result is ready to join.
        turn_ended,

        pub const Tool = struct { name: []u8, input_json: []u8 };
        pub const ToolResult = struct {
            name: []u8,
            content: []u8,
            summary: ?[]u8 = null,
            is_error: bool,
        };
        pub const SteeringConsumed = struct { text: []u8, count: usize };
    };

    pub fn deinit(self: *const TurnEvent, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .text, .thinking => |bytes| gpa.free(bytes),
            .tool_start => |tool| {
                gpa.free(tool.name);
                gpa.free(tool.input_json);
            },
            .tool_result => |result| {
                gpa.free(result.name);
                gpa.free(result.content);
                if (result.summary) |summary| gpa.free(summary);
            },
            .steering_consumed => |consumed| gpa.free(consumed.text),
            .usage, .stream_reset, .turn_ended => {},
        }
    }
};

/// A message from any producer task to the render consumer. Turn-owned events
/// carry a generation. Input and presentation-control events do not.
pub const UiEvent = union(enum) {
    keys: []u8,
    turn: TurnEvent,
    tick,
    resize,

    pub fn deinit(self: *const UiEvent, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .keys => |bytes| gpa.free(bytes),
            .turn => |*event| event.deinit(gpa),
            .tick, .resize => {},
        }
    }
};

/// Build an empty session at the default terminal size. It paints through
/// `writer` and shows `model` and `effort` until a command changes them.
/// Infallible: the components own no resources until used.
pub fn init(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    model: ai.models.Model,
    effort: ai.llm.Effort,
) Session {
    var self: Session = .{
        .gpa = gpa,
        .transcript = Transcript.init(gpa),
        .notice = null,
        .editor = ui.Editor.init(gpa),
        .view = terminal.View.init(gpa, writer),
        .page_view = terminal.View.init(gpa, writer),
        .mode = .prompt,
        .columns = 80,
        .rows = 24,
        .dirty = false,
        .stats_shown = .{},
        .model_shown = model,
        .effort_shown = effort,
        .account_shown = .anthropic_subscription,
        .steering = .empty,
        .steering_retained_count = 0,
        .steering_consumed_count = 0,
        .steering_view = .empty,
        .turn_origin = null,
    };
    self.page_view.preserveScrollback();
    return self;
}

pub fn deinit(self: *Session) void {
    self.deinitMode();
    self.clearNotice();
    self.clearSteering();
    self.steering.deinit(self.gpa);
    self.steering_view.deinit(self.gpa);
    self.transcript.deinit();
    self.page_view.deinit();
    self.view.deinit();
    self.editor.deinit();
}

/// Clear the visible conversation and its usage and steering snapshots.
/// Commands run only in prompt mode, so the reset cannot discard live turn state.
pub fn resetConversation(self: *Session) void {
    std.debug.assert(self.mode == .prompt);
    self.transcript.truncate(0);
    self.clearNotice();
    self.stats_shown = .{};
    self.clearSteering();
}

/// Clear the transient notice. The regular footer returns on the next frame.
pub fn clearNotice(self: *Session) void {
    if (self.notice) |notice| {
        self.gpa.free(notice.content);
        self.notice = null;
        self.dirty = true;
    }
}

/// Replace the transient notice and take ownership of `notice.content`.
fn setNotice(self: *Session, notice: ai.command.Outcome.Message) void {
    self.clearNotice();
    self.notice = notice;
    self.dirty = true;
}

/// Copy and show a transient notice produced directly by the session.
fn showNotice(
    self: *Session,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    self.setNotice(.{ .content = try self.gpa.dupe(u8, text), .severity = severity });
}

/// Free whatever the current mode owns.
fn deinitMode(self: *Session) void {
    switch (self.mode) {
        .prompt => {},
        .turn => |*turn| {
            self.freeTurn(turn);
            self.dropTurnOrigin();
        },
        .picking => |*picking| picking.picker.deinit(),
        .viewing => |*page| page.deinit(),
    }
}

/// Apply one turn worker event to the model, mark it dirty, and free the
/// event's bytes. This function never paints. It drops an event unless its
/// captured generation is still the active turn.
pub fn applyTurnEvent(self: *Session, event: *const TurnEvent) !bool {
    defer event.deinit(self.gpa);
    const turn = self.activeTurn() orelse return false;
    if (event.generation != turn.generation) return false;
    if (event.progress_sequence != 0) {
        std.debug.assert(event.progress_sequence == turn.progress_sequence_applied + 1);
        std.debug.assert(event.progress_sequence_committed <= turn.progress_sequence_applied);
        if (event.progress_sequence_committed > turn.progress_sequence_checkpoint) {
            self.transcript.endMessage();
            turn.transcript_checkpoint = self.transcript.blocks().len;
            turn.progress_sequence_checkpoint = event.progress_sequence_committed;
        }
    }
    self.dirty = true;
    switch (event.payload) {
        .text => |delta| try self.transcript.appendStream(.model, delta),
        .thinking => |delta| try self.transcript.appendStream(.thinking, delta),
        .tool_start => |*tool| {
            self.transcript.endMessage();
            try pushTool(turn, self.gpa, tool);
        },
        .tool_result => |result| try self.applyToolResult(result),
        .usage => |stats| self.stats_shown = stats,
        .stream_reset => self.transcript.discardMessage(),
        .steering_consumed => |consumed| {
            // Show the folded batch and hide its rows from the queue view, but
            // retain the rich drafts: a consumed batch can still roll back
            // (until its following reply commits). The receipt — not this
            // event — decides whether to drop or recover each draft.
            try self.transcript.append(.user, false, consumed.text);
            // Advance the consumed frontier, then the view frontier to cover it,
            // without double-counting drafts an earlier Alt+Up already hid.
            self.steering_consumed_count =
                @min(self.steering_consumed_count + consumed.count, self.steering.items.len);
            self.steering_retained_count =
                @max(self.steering_retained_count, self.steering_consumed_count);
        },
        .turn_ended => {
            turn.progress_sequence_applied = event.progress_sequence;
            return true;
        },
    }
    turn.progress_tick_last = turn.activity_tick;
    if (event.progress_sequence != 0)
        turn.progress_sequence_applied = event.progress_sequence;
    return false;
}

/// Apply progress taken directly from the shared queue after its worker has been
/// joined for cancellation. An earlier event can already belong to the consumer's
/// current batch, so a sequence gap is an allowed presentation gap. Discard this
/// and every later queued event rather than apply progress out of order.
pub fn applyCanceledTurnEvent(self: *Session, event: *const TurnEvent) !void {
    const turn = self.activeTurn() orelse {
        event.deinit(self.gpa);
        return;
    };
    const sequence_gap = event.progress_sequence != 0 and
        (turn.progress_sequence_applied == std.math.maxInt(u64) or
            event.progress_sequence != turn.progress_sequence_applied + 1);
    if (event.generation != turn.generation or sequence_gap) {
        event.deinit(self.gpa);
        return;
    }
    _ = try self.applyTurnEvent(event);
}

/// Record a finished tool call in the transcript: the tool's summary (or its
/// first output line, when it gave none) beside the box it closes. Then free
/// that box.
fn applyToolResult(self: *Session, result: TurnEvent.Payload.ToolResult) !void {
    const detail = result.summary orelse first: {
        const line_end = std.mem.indexOfScalar(u8, result.content, '\n') orelse result.content.len;
        break :first result.content[0..line_end];
    };
    const finished = if (self.activeTurn()) |turn| takeTool(turn, result.name) else null;
    defer if (finished) |*tool| self.freeTool(tool);
    const arguments = if (finished) |tool| tool.input_json else "";
    const text = try std.fmt.allocPrint(self.gpa, "Tool: {s} {s}\n{s}: {s}", .{
        result.name,
        arguments,
        if (result.is_error) "Error" else "Result",
        detail,
    });
    defer self.gpa.free(text);
    try self.transcript.append(.tool_result, result.is_error, text);
}

/// Apply a command outcome to the model: replace its notice, record its event,
/// or open its picker.
pub fn applyOutcome(self: *Session, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .notice => |notice| self.setNotice(notice),
        .event => |event| {
            defer self.gpa.free(event.content);
            try self.transcript.append(.event, event.severity == .failure, event.content);
        },
        .pick => |pick| try self.openPicker(pick),
        // The app intercepts prompt, account, conversation, and inspection
        // actions. They never reach the io-free session.
        .prompt,
        .login,
        .logout,
        .switch_account,
        .new_conversation,
        .show_system_prompt,
        => unreachable,
    }
    self.dirty = true;
}

/// Enter picker mode over a command's options. Takes ownership of `pick.options`.
fn openPicker(self: *Session, pick: ai.command.Outcome.Pick) !void {
    errdefer {
        for (pick.options) |option| self.gpa.free(option);
        self.gpa.free(pick.options);
    }
    const picker = try ui.Picker.init(self.gpa, pick.title, pick.options, pick.current);
    // Init succeeded and now owns the options. Drop whatever the previous mode
    // held before the replacement, so a picker opened over a live turn or
    // picker cannot leak.
    self.deinitMode();
    self.mode = .{ .picking = .{
        .picker = picker,
        .select = pick.select,
        .cancellation_message = pick.cancellation_message,
    } };
}

/// Leave picker mode and free the picker. A no-op in any other mode.
pub fn closePicker(self: *Session) void {
    switch (self.mode) {
        .picking => |*picking| {
            picking.picker.deinit();
            self.mode = .prompt;
            self.dirty = true;
        },
        else => {},
    }
}

/// Close the picker and show its cancellation until the next user action.
pub fn cancelPicker(self: *Session) !void {
    const cancellation_message = switch (self.mode) {
        .picking => |picking| picking.cancellation_message,
        else => return,
    };
    self.closePicker();
    try self.showNotice(.information, cancellation_message);
}

/// Open an owned read-only page over an idle conversation.
pub fn openPage(self: *Session, options: *const ui.Page.Options) !void {
    std.debug.assert(self.mode == .prompt);
    var page = try ui.Page.init(self.gpa, options);
    page.reflow(.{ .columns = self.columns, .rows = self.rows });
    self.page_view.forget();
    self.page_view.invalidate();
    self.mode = .{ .viewing = page };
    self.dirty = true;
}

/// Close a page silently and request a non-destructive conversation repaint.
pub fn closePage(self: *Session) void {
    switch (self.mode) {
        .viewing => |*page| {
            page.deinit();
            self.mode = .prompt;
            self.dirty = true;
        },
        else => {},
    }
}

/// Reserve capacity for one more queued steering draft. `App.submitSteering`'s
/// channel push then becomes the only fallible step before the draft moves in.
/// Once reserved, `commitSteeringDraft` cannot fail, so the worker never owns a
/// message the mirror lacks a recovery draft for.
pub fn reserveSteering(self: *Session) !void {
    try self.steering.ensureUnusedCapacity(self.gpa, 1);
}

/// Move a detached steering draft into the mirror. Infallible after
/// `reserveSteering`. Takes ownership and leaves `draft` empty.
pub fn commitSteeringDraft(self: *Session, draft: *ui.Editor.Draft) void {
    self.steering.appendAssumeCapacity(draft.*);
    draft.* = .empty;
    self.dirty = true;
}

/// Preflight enough editor capacity to recall any queue suffix. The mirror is
/// consumer-owned and remains stable until `recallSteering`.
pub fn reserveSteeringRecall(self: *Session) !void {
    try self.editor.reserveDrafts(self.steering.items);
}

/// Recall the queue-length suffix into the editor in submission order. The
/// remaining prefix is in flight and stays hidden until consumed or restored.
/// Infallible after `reserveSteeringRecall`.
pub fn recallSteering(self: *Session, pending_count: usize) void {
    std.debug.assert(pending_count <= self.steering.items.len);
    const pending_start = self.steering.items.len - pending_count;
    for (self.steering.items[pending_start..]) |*draft| self.editor.appendDraft(draft);
    self.steering.shrinkRetainingCapacity(pending_start);
    self.steering_retained_count = self.steering.items.len;
    self.steering_consumed_count = @min(self.steering_consumed_count, self.steering.items.len);
    self.dirty = true;
}

/// Retain the submitted prompt's rich draft and set the turn's initial transcript
/// checkpoint. An abnormal exit that commits nothing can then return the prompt.
/// Takes ownership of `prompt` and leaves it empty.
pub fn retainTurnPrompt(self: *Session, prompt: *ui.Editor.Draft, transcript_base: usize) void {
    std.debug.assert(self.turn_origin == null);
    const turn = self.activeTurn() orelse unreachable;
    std.debug.assert(transcript_base <= self.transcript.blocks().len);
    turn.transcript_checkpoint = transcript_base;
    self.turn_origin = .{ .prompt = prompt.* };
    prompt.* = .empty;
}

/// Drop the live turn's rewind anchor and free the retained prompt draft. By
/// then it has either entered committed history or moved back into the editor.
fn dropTurnOrigin(self: *Session) void {
    if (self.turn_origin) |*origin| {
        origin.prompt.deinit(self.gpa);
        self.turn_origin = null;
    }
}

/// Preflight editor capacity to put the returned prompt and every uncommitted
/// steering draft above the in-progress line. Abnormal receipt reconciliation
/// then cannot fail. This reserves the prompt before the receipt says whether
/// it returns, so a partial commit intentionally over-reserves.
pub fn reserveSteeringRestore(self: *Session) !void {
    const lead: ?*const ui.Editor.Draft =
        if (self.turn_origin) |*origin| &origin.prompt else null;
    try self.editor.reserveComposition(lead, self.steering.items);
}

/// Preflight only the drafts a known failed receipt will restore. This avoids
/// capacity for an origin or steering prefix already committed to history.
pub fn reserveFailureRestore(self: *Session, receipt: *const ai.Agent.Receipt) !void {
    const committed = receipt.history_end != receipt.history_base;
    var lead: ?*const ui.Editor.Draft = null;
    if (!committed) {
        if (self.turn_origin) |*origin| lead = &origin.prompt;
    }
    const steering_start = @min(receipt.steering_committed_count, self.steering.items.len);
    try self.editor.reserveComposition(lead, self.steering.items[steering_start..]);
}

/// Whether any rich steering record remains live or retained in flight.
pub fn hasSteering(self: *const Session) bool {
    return self.steering.items.len > 0;
}

/// Drop every steering draft and free its atoms.
pub fn clearSteering(self: *Session) void {
    for (self.steering.items) |*draft| draft.deinit(self.gpa);
    self.steering.clearRetainingCapacity();
    self.steering_retained_count = 0;
    self.steering_consumed_count = 0;
    self.dirty = true;
}

/// Borrowed compact `Queued message:` rows: each non-retained draft's collapsed
/// visible text. Each paint rebuilds them without a per-frame allocation.
/// Borrows stay valid only until the mirror next mutates.
fn steeringView(self: *Session) ![]const []const u8 {
    std.debug.assert(self.steering_retained_count <= self.steering.items.len);
    self.steering_view.clearRetainingCapacity();
    for (self.steering.items[self.steering_retained_count..]) |draft|
        try self.steering_view.append(self.gpa, draft.visible.items);
    return self.steering_view.items;
}

/// Close any open model run, then enter turn mode with fresh border activity and
/// no active tools.
pub fn beginTurn(self: *Session, generation: u64) void {
    self.transcript.endMessage();
    self.mode = .{ .turn = .{
        .generation = generation,
        .progress_sequence_applied = 0,
        .progress_sequence_checkpoint = 0,
        .transcript_checkpoint = self.transcript.blocks().len,
        .activity_tick = 0,
        .progress_tick_last = 0,
        .tools = .empty,
        .box_view = .empty,
    } };
    self.dirty = true;
}

/// Abort the running turn's model state: close the open run, drop the turn's
/// chrome, and record the cancellation. The io-side worker teardown is the
/// caller's.
pub fn abortTurn(self: *Session) !void {
    self.endTurn();
    self.dirty = true;
    try self.transcript.append(.event, false, "You canceled the turn.");
}

/// Apply a completed turn's receipt, append any cutoff event, and end it. Late
/// steering remains pending so the app can promote it into a successor turn.
pub fn endTurnWithReceipt(self: *Session, receipt: *const ai.Agent.Receipt) !void {
    self.applyReceiptNormal(receipt);
    self.dropTurnOrigin();
    if (receipt.truncated) try self.transcript.append(.event, false, truncated_event);
    self.transcript.endMessage();
    self.endTurn();
}

/// Rewind a failed turn to committed history, return every uncommitted draft,
/// append its event, and end it. Infallible after `reserveFailureRestore` until
/// the event append. Borrows `error_text`. The caller frees it.
pub fn failTurnWithReceipt(
    self: *Session,
    receipt: *const ai.Agent.Receipt,
    error_text: ?[]const u8,
) !void {
    self.reconcileAbnormalReceipt(receipt);
    if (receipt.truncated) try self.transcript.append(.event, false, truncated_event);
    if (error_text) |text| try self.transcript.append(.event, true, text);
    self.transcript.endMessage();
    self.endTurn();
}

/// Resolve the rich steering mirror on a completed terminal: drop the committed
/// prefix (now in history) and make every remaining draft pending again.
/// Late-steering handling can then start it as a new turn. Infallible.
fn applyReceiptNormal(self: *Session, receipt: *const ai.Agent.Receipt) void {
    self.dropSteeringPrefix(receipt.steering_committed_count);
    self.steering_retained_count = 0;
    self.steering_consumed_count = 0;
    self.dirty = true;
}

/// Resolve a genuine user cancellation against its receipt and the worker's
/// presentation commit frontier, then reconcile it to committed history.
/// Infallible after `reserveSteeringRestore`.
pub fn cancelReceipt(
    self: *Session,
    receipt: *const ai.Agent.Receipt,
    progress_sequence_committed: u64,
) void {
    const turn = self.activeTurn() orelse unreachable;
    if (progress_sequence_committed > turn.progress_sequence_checkpoint and
        progress_sequence_committed == turn.progress_sequence_applied)
    {
        // No later event carried the final frontier, but the consumer applied
        // every event through it. When committed progress is missing, keep the
        // older checkpoint: the gap can contain a stream reset that invalidates
        // the currently displayed attempt.
        self.transcript.endMessage();
        turn.transcript_checkpoint = self.transcript.blocks().len;
        turn.progress_sequence_checkpoint = progress_sequence_committed;
    }
    self.reconcileAbnormalReceipt(receipt);
}

/// Rewind presentation to the latest agent checkpoint and compose the editor
/// from the uncommitted origin, steering, and in-progress text.
fn reconcileAbnormalReceipt(self: *Session, receipt: *const ai.Agent.Receipt) void {
    self.dropSteeringPrefix(receipt.steering_committed_count);
    const turn = self.activeTurn() orelse unreachable;
    self.transcript.truncate(turn.transcript_checkpoint);

    const committed = receipt.history_end != receipt.history_base;
    var lead: ?*ui.Editor.Draft = null;
    if (!committed) {
        if (self.turn_origin) |*origin| lead = &origin.prompt;
    }
    self.editor.prependComposition(lead, self.steering.items);
    self.steering.clearRetainingCapacity();
    self.steering_retained_count = 0;
    self.steering_consumed_count = 0;
    self.dropTurnOrigin();
    self.dirty = true;
}

/// Drop and free the leading `count` committed steering drafts. The caller
/// resets the steering counts to the retention it wants afterward.
fn dropSteeringPrefix(self: *Session, count: usize) void {
    var dropped: usize = 0;
    while (dropped < count and self.steering.items.len > 0) : (dropped += 1) {
        var draft = self.steering.orderedRemove(0);
        draft.deinit(self.gpa);
    }
}

/// Free the finished turn's tool state and return to prompt mode.
pub fn endTurn(self: *Session) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
    self.dropTurnOrigin();
    self.mode = .prompt;
}

/// Assemble the visible scene from the model, project it at `size`, and record
/// the size as the last laid-out dimensions. No tty or agent, so tests can
/// drive the consumer from a scripted event sequence.
pub fn paint(self: *Session, size: terminal.View.Size) !void {
    self.columns = size.columns;
    self.rows = size.rows;
    switch (self.mode) {
        .viewing => |*page| {
            page.reflow(size);
            const scene: layout.Scene = .{ .page = page };
            try layout.project(&self.page_view, size, &scene);
            return;
        },
        else => {},
    }

    const status: ui.status.Info = .{
        .last = self.stats_shown.last,
        .cost = self.stats_shown.cost,
        .context_window = self.model_shown.context_window,
        .model = self.model_shown.name,
        .effort = @tagName(self.effort_shown),
        .account = self.account_shown,
        .quota = self.stats_shown.quota,
        .notice = if (self.notice) |notice| .{
            .text = notice.content,
            .is_error = notice.severity == .failure,
        } else null,
    };

    const tail: layout.Tail = switch (self.mode) {
        .prompt => prompt: {
            self.editor.reflow(size);
            break :prompt .{ .prompt = &self.editor };
        },
        .turn => |*turn| turn: {
            self.editor.reflow(size);
            break :turn .{ .turn = .{
                .tools = try turn.boxes(self.gpa),
                .activity = turn.activity(),
                .steering = try self.steeringView(),
                .editor = &self.editor,
            } };
        },
        .picking => |*picking| picking: {
            picking.picker.reflow(size);
            break :picking .{ .picking = &picking.picker };
        },
        .viewing => unreachable,
    };
    const scene: layout.Scene = .{ .conversation = .{
        .transcript = self.transcript.blocks(),
        .tail = tail,
        .status = &status,
    } };
    try layout.project(&self.view, size, &scene);
}

/// Move the terminal cursor below the interface. Call once at shutdown, so the
/// shell prompt after exit does not overwrite the input box and status line.
pub fn parkCursor(self: *Session) !void {
    try self.view.parkCursor();
}

/// Advance the activity clock and report whether this tick repaints. A turn
/// advances without marking the model dirty, so motion continues between model
/// events.
pub fn advanceFrame(self: *Session) bool {
    var activity_changed = false;
    if (self.activeTurn()) |turn| {
        turn.activity_tick +%= 1;
        const size: terminal.View.Size = .{ .columns = self.columns, .rows = self.rows };
        const body_rows = self.editor.rows(size) - ui.paint.frame_border_rows;
        const activity = turn.activity();
        activity_changed = ui.paint.activityChanged(&activity, &.{
            .columns = size.columns,
            .body_rows = body_rows,
        });
    }
    return self.dirty or activity_changed;
}

/// Whether a component wants continuous frames: the active turn's border.
pub fn animating(self: *const Session) bool {
    return switch (self.mode) {
        .turn => true,
        else => false,
    };
}

/// The running turn, if a turn is streaming.
fn activeTurn(self: *Session) ?*Turn {
    return switch (self.mode) {
        .turn => |*turn| turn,
        else => null,
    };
}

/// Allocate a running tool call's owned strings and record it on `turn`. Ends at
/// a committed append so a later fallible repaint can never orphan or double-free
/// the strings. A failure here retains nothing.
fn pushTool(turn: *Turn, gpa: std.mem.Allocator, tool: *const TurnEvent.Payload.Tool) !void {
    const box = try std.fmt.allocPrint(gpa, "Tool: {s} {s}", .{
        tool.name,
        tool.input_json,
    });
    errdefer gpa.free(box);
    const name_copy = try gpa.dupe(u8, tool.name);
    errdefer gpa.free(name_copy);
    const arguments = try gpa.dupe(u8, tool.input_json);
    errdefer gpa.free(arguments);
    try turn.tools.append(gpa, .{ .name = name_copy, .input_json = arguments, .box = box });
}

/// Remove the running tool matching `name` (or the oldest, if none matches) and
/// hand it to the caller to free.
fn takeTool(turn: *Turn, name: []const u8) ?ActiveTool {
    for (turn.tools.items, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, name)) return turn.tools.orderedRemove(index);
    }
    if (turn.tools.items.len == 0) return null;
    return turn.tools.orderedRemove(0);
}

fn freeTool(self: *Session, tool: *const ActiveTool) void {
    self.gpa.free(tool.name);
    self.gpa.free(tool.input_json);
    self.gpa.free(tool.box);
}

fn freeTurn(self: *Session, turn: *Turn) void {
    for (turn.tools.items) |*tool| self.freeTool(tool);
    turn.tools.deinit(self.gpa);
    turn.box_view.deinit(self.gpa);
}

const test_model = ai.models.get(.anthropic, "claude-sonnet-4-6") orelse
    @compileError("test model is not in the model table");

fn applyEvent(session: *Session, generation: u64, payload: TurnEvent.Payload) !void {
    _ = try session.applyTurnEvent(&.{ .generation = generation, .payload = payload });
}

// Queue a plain-text (atom-free) steering draft, as a submitted literal line does.
fn queueSteeringText(session: *Session, text: []const u8) !void {
    var editor = ui.Editor.init(session.gpa);
    defer editor.deinit();
    try editor.insert(text);
    try session.reserveSteering();
    var draft = editor.detachTrimmed();
    session.commitSteeringDraft(&draft);
}

fn finishTurn(session: *Session, committed: usize) !void {
    try session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = committed,
    });
}

// Mirrors the read loop's inner pipeline without a tty: one read chunk carries
// several keystrokes, which must decode, edit, and paint into the frame.
test "a read chunk drives the editor and paints the result" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = terminal.Input.init(gpa);
    defer input.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    try input.feed("he\x7fllo");
    while (input.next()) |event| switch (event) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .backspace => editor.backspace(),
        else => {},
    };
    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: ui.paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();

    try std.testing.expectEqualStrings("hllo", editor.visible());
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hllo") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.sync_set) != null);
}

test "a bracketed paste cannot emit terminal controls" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = terminal.Input.init(gpa);
    defer input.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    const payload = "paste\x1b[9A\x1b]52;c;cGFzdGU=\x07\x1bPdata\x1b\\done";
    try input.feed(terminal.escape.paste_begin ++ payload ++ terminal.escape.paste_end);
    const event = input.next().?;
    switch (event) {
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        else => return error.UnexpectedInput,
    }
    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: ui.paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 120, .base = 0, .skip = 0 };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();

    const painted = out.written();
    for ([_][]const u8{
        "paste", "[9A", "]52;c;cGFzdGU=", "Pdata", "done",
        "\u{200B}�\u{200B}",
    }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, painted, text) != null);
    }
    for ([_][]const u8{ "\x1b[9A", "\x1b]52;c;cGFzdGU=\x07", "\x1bPdata\x1b\\" }) |control| {
        try std.testing.expect(std.mem.indexOf(u8, painted, control) == null);
    }
}

// A large paste travels the real Input -> editor -> render pipeline: it collapses
// to a compact marker on screen yet expands to its exact bytes for a send.
test "a large bracketed paste collapses to a marker through the real pipeline" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = terminal.Input.init(gpa);
    defer input.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    const payload = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk"; // 11 logical lines
    try input.feed(terminal.escape.paste_begin ++ payload ++ terminal.escape.paste_end);
    while (input.next()) |event| switch (event) {
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        else => return error.UnexpectedInput,
    };
    // The editor shows the compact marker, not the payload.
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());

    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: ui.paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[Paste #1: 11 lines]") != null);

    // It expands back to the exact bytes for a send boundary.
    const expanded = try editor.expanded(.whole_prompt);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

test "a notice replaces its predecessor without entering the transcript" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .information, "First notice.", .{}),
    );
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Second notice.", .{}),
    );

    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expectEqualStrings("Second notice.", session.notice.?.content);
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, session.notice.?.severity);
    session.clearNotice();
    try std.testing.expect(session.notice == null);
}

test "a notice replaces the footer and clearing restores the status" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try session.paint(.{ .columns = 80, .rows = 24 });
    const notice_start = out.written().len;
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Temporary notice.", .{}),
    );
    try session.paint(.{ .columns = 80, .rows = 24 });
    const notice_frame = out.written()[notice_start..];
    try std.testing.expect(std.mem.indexOf(u8, notice_frame, "Error: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice_frame, "Temporary notice.") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice_frame, test_model.name) == null);

    const status_start = out.written().len;
    session.clearNotice();
    try session.paint(.{ .columns = 80, .rows = 24 });
    const status_frame = out.written()[status_start..];
    try std.testing.expect(std.mem.indexOf(u8, status_frame, test_model.name) != null);
}

test "an event survives notice clearing until the conversation resets" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "Pith changed the model.", .{}),
    );
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Temporary notice.", .{}),
    );
    session.clearNotice();

    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "Pith changed the model.",
        session.transcript.blocks()[0].event.text.items,
    );
    session.resetConversation();
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(session.notice == null);
}

// The consumer seam without real io: a scripted turn's worker events drive the
// transcript, usage, and turn teardown. The events mark the model dirty but
// never paint. One paint then renders the coalesced frame.
test "scripted stream events drive the model and one coalesced paint" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    // Owned payloads, exactly as a producer task allocates them.
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "he") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "llo") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .content = try gpa.dupe(u8, "first line\nsecond"),
        .is_error = false,
    } });
    // The result replaces its running box at once, not at turn end.
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.tools.items.len);
    try applyEvent(&session, 1, .{ .usage = .{
        .cost = 1.5,
        .saved = 0.25,
        .last = .{ .input = 10, .output = 20 },
    } });

    // The applied events mark the model dirty but paint nothing.
    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(f64, 1.5), session.stats_shown.cost);

    // A clean end leaves turn mode.
    try finishTurn(&session, 0);
    try std.testing.expect(!session.animating());

    // One paint renders the coalesced frame: streamed text and the tool result.
    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "first line") != null);
}

test "a tool result box shows the summary instead of the output" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .content = try gpa.dupe(u8, "line one\nline two\nline three"),
        .summary = try gpa.dupe(u8, "Lines: 3 · Size: 27 B"),
        .is_error = false,
    } });
    try finishTurn(&session, 0);
    try session.paint(.{ .columns = 80, .rows = 24 });

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 3 · Size: 27 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "line one") == null);
}

// A cut-off answer is committed history, so the turn's end says it is partial
// rather than letting it read as a complete reply.
test "a truncated receipt appends an event after the answer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "half an ans") });
    try session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 2,
        .steering_committed_count = 0,
        .truncated = true,
    });

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("half an ans", blocks[0].model.items);
    try std.testing.expect(!blocks[1].event.is_error);
    try std.testing.expectEqualStrings(truncated_event, blocks[1].event.text.items);

    // A turn that both truncated and failed reports the cutoff before the error.
    session.beginTurn(2);
    const receipt: ai.Agent.Receipt = .{
        .history_base = 2,
        .history_end = 2,
        .steering_committed_count = 0,
        .truncated = true,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "boom");
    const after = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), after.len);
    try std.testing.expectEqualStrings(truncated_event, after[2].event.text.items);
    try std.testing.expect(after[3].event.is_error);
    try std.testing.expectEqualStrings("boom", after[3].event.text.items);
}

test "streamed and tool text cannot emit terminal controls" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const streamed = "reply\x1b[8A\x1b]52;c;bW9kZWw=\x07\x1b_payload\x1b\\done";
    const tool = "tool\x1b]52;c;dG9vbA==\x1b\\\x1bPpayload\x1b\\\xc2\x9b2Jdone";
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, streamed) });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .content = try gpa.dupe(u8, tool),
        .is_error = false,
    } });
    try finishTurn(&session, 0);
    try session.paint(.{ .columns = 160, .rows = 24 });

    const painted = out.written();
    for ([_][]const u8{
        "reply",  "[8A", "]52;c;bW9kZWw=", "_payload", "tool", "]52;c;dG9vbA==", "Ppayload",
        "2Jdone",
        "\u{200B}�\u{200B}",
    }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, painted, text) != null);
    }
    for ([_][]const u8{
        "\x1b[8A",
        "\x1b]52;c;bW9kZWw=\x07",
        "\x1b_payload\x1b\\",
        "\x1b]52;c;dG9vbA==\x1b\\",
        "\x1bPpayload\x1b\\",
        "\xc2\x9b2J",
    }) |control| {
        try std.testing.expect(std.mem.indexOf(u8, painted, control) == null);
    }
}

// A worker event can arrive after the turn ends (a straggler from a cancelled
// turn). The consumer frees and drops it rather than append it.
test "stream events are dropped once the turn is over" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "straggler") });
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(!session.dirty);
}

// Cancellation, resubmission, and these delayed events can all be entries in one
// batch that App already drained from the shared queue.
test "a cancelled turn's stale output and completion cannot affect its successor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "turn A") });
    try session.abortTurn();
    session.beginTurn(2);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "stale A") });
    try std.testing.expect(!try session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .turn_ended,
    }));
    try std.testing.expect(session.animating());

    try applyEvent(&session, 2, .{ .text = try gpa.dupe(u8, "turn B") });
    try std.testing.expect(try session.applyTurnEvent(&.{
        .generation = 2,
        .payload = .turn_ended,
    }));
    try finishTurn(&session, 0);
    try std.testing.expect(!session.animating());
    // Three blocks: the stale error appended no event block either.
    try std.testing.expectEqual(@as(usize, 3), session.transcript.blocks().len);
    try std.testing.expectEqualStrings("turn B", session.transcript.blocks()[2].model.items);
}

test "committing a steering draft empties the source" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("move me");
    var draft = editor.detachTrimmed();
    defer draft.deinit(gpa);

    try session.reserveSteering();
    session.commitSteeringDraft(&draft);
    try std.testing.expectEqual(@as(usize, 0), draft.visible.items.len);
    try std.testing.expectEqual(@as(usize, 0), draft.atoms.items.len);
    try std.testing.expectEqualStrings("move me", session.steering.items[0].visible.items);
}

// Queued steering shows in the tail. A consumed event moves the combined text
// into the transcript as one user block and drops the queued rows.
test "steering queues, then a consumed event shows it and clears the queue" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try queueSteeringText(&session, "fix it");
    try queueSteeringText(&session, "and test");
    try std.testing.expectEqual(@as(usize, 2), session.steering.items.len);
    try std.testing.expectEqualStrings("fix it", session.steering.items[0].visible.items);

    try applyEvent(&session, 1, .{ .steering_consumed = .{
        .text = try gpa.dupe(u8, "fix it\n\nand test"),
        .count = 2,
    } });
    // The combined batch shows as one user block. Its compact rows drop from
    // the view. The session retains the rich drafts (hidden), so a rolled-back
    // batch stays recoverable until the receipt resolves it.
    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "fix it\n\nand test",
        session.transcript.blocks()[0].user.items,
    );
    try std.testing.expectEqual(@as(usize, 2), session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.steering_retained_count);
    try std.testing.expectEqual(@as(usize, 0), (try session.steeringView()).len);

    // A normal completion whose receipt committed the batch drops those drafts.
    try finishTurn(&session, 2);
    try std.testing.expectEqual(@as(usize, 0), session.steering.items.len);
}

// A genuine user cancel with a committed prefix drops those drafts (they live in
// history) and restores only the uncommitted suffix to the editor.
test "cancelReceipt drops the committed prefix and restores the uncommitted suffix" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try queueSteeringText(&session, "committed");
    try queueSteeringText(&session, "restore me");
    // The worker consumed both messages, so both drafts are retained in flight.
    try applyEvent(&session, 1, .{ .steering_consumed = .{
        .text = try gpa.dupe(u8, "committed\n\nrestore me"),
        .count = 2,
    } });
    try std.testing.expectEqual(@as(usize, 2), session.steering_retained_count);

    // Only the first message committed before the cancel rolled back the rest.
    try session.reserveSteeringRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 1,
    }, 0);

    // The committed draft is gone. The uncommitted one returns to the editor.
    // The counts reset.
    try std.testing.expectEqual(@as(usize, 0), session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.steering_retained_count);
    try std.testing.expectEqual(@as(usize, 0), session.steering_consumed_count);
    try std.testing.expectEqualStrings("restore me", session.editor.visible());
}

// A steered large paste shows as its collapsed marker in the compact queue view,
// never its payload. The payload rides along in the rich draft for recall.
test "the steering view shows a paste collapsed, not its payload" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const payload = "secret line\n" ** 15; // 16 logical lines: collapses to a marker
    try session.editor.paste(payload, true);
    try session.reserveSteering();
    var draft = session.editor.detachTrimmed();
    session.commitSteeringDraft(&draft);

    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "[Paste #1: 16 lines]") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "secret line") == null);
}

test "opening a picker over a turn releases its retained prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    var prompt = try ui.Editor.Draft.fromText(gpa, "first");
    session.retainTurnPrompt(&prompt, 0);
    const options = try gpa.alloc([]const u8, 1);
    options[0] = try gpa.dupe(u8, "choice");
    try session.applyOutcome(.{ .pick = .{
        .select = undefined,
        .title = "Select an option",
        .cancellation_message = "You canceled the option selection.",
        .options = options,
        .current = null,
    } });
    try std.testing.expect(session.mode == .picking);
    try std.testing.expect(session.turn_origin == null);

    session.closePicker();
    session.beginTurn(2);
    var next_prompt = try ui.Editor.Draft.fromText(gpa, "second");
    session.retainTurnPrompt(&next_prompt, 0);
    session.endTurn();
    try std.testing.expect(session.turn_origin == null);
}

// The activity clock advances between stream events, but a corner or vertical
// cell dwells for an extra tick without a repaint.
test "activity ticks use aspect-aware repaint timing" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    session.dirty = false;
    session.mode.turn.activity_tick = 38;
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 39), session.mode.turn.activity_tick);
    try std.testing.expect(!session.advanceFrame());
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 41), session.mode.turn.activity_tick);
    session.mode.turn.activity_tick = std.math.maxInt(u64);
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 0), session.mode.turn.activity_tick);
    session.deinitMode();

    // Idle — clean and not animating — repaints nothing.
    session.mode = .prompt;
    session.dirty = false;
    try std.testing.expect(!session.advanceFrame());

    // New model content repaints even without animation.
    session.dirty = true;
    try std.testing.expect(session.advanceFrame());
}

test "accepted turn progress restarts border growth without resetting motion" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(7);
    session.mode.turn.activity_tick = 125;
    session.mode.turn.progress_tick_last = 5;

    try applyEvent(&session, 6, .{ .usage = .{} });
    try std.testing.expectEqual(@as(u64, 5), session.mode.turn.progress_tick_last);

    try applyEvent(&session, 7, .{ .usage = .{} });
    const activity = session.mode.turn.activity();
    try std.testing.expectEqual(@as(u64, 125), activity.motion_tick);
    try std.testing.expectEqual(@as(u64, 0), activity.progress_age_ticks);
}

test "a failure with nothing committed rewinds the tail and returns the prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try session.transcript.append(.event, false, "earlier");
    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, false, "my prompt");
    try session.transcript.appendStream(.model, "partial reply");
    var prompt = try ui.Editor.Draft.fromText(gpa, "my prompt");
    session.retainTurnPrompt(&prompt, base);
    try queueSteeringText(&session, "steer");
    try session.editor.insert("typing");

    const receipt: ai.Agent.Receipt = .{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 0,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "Overloaded");

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("earlier", blocks[0].event.text.items);
    try std.testing.expect(blocks[1].event.is_error);
    try std.testing.expectEqualStrings("Overloaded", blocks[1].event.text.items);
    try std.testing.expectEqualStrings("my prompt\n\nsteer\n\ntyping", session.editor.visible());
    try std.testing.expect(session.turn_origin == null);
    try std.testing.expect(!session.hasSteering());
}

test "a failure after a committed round keeps it and restores only steering" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, false, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round one") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "read"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round two partial") },
    });
    try queueSteeringText(&session, "restore me");

    const receipt: ai.Agent.Receipt = .{
        .history_base = 0,
        .history_end = 2,
        .steering_committed_count = 0,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "boom");

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].user.items);
    try std.testing.expectEqualStrings("round one", blocks[1].model.items);
    try std.testing.expect(blocks[2].event.is_error);
    try std.testing.expectEqualStrings("boom", blocks[2].event.text.items);
    try std.testing.expectEqualStrings("restore me", session.editor.visible());
    try std.testing.expect(session.turn_origin == null);
    try std.testing.expect(!session.hasSteering());
}

// With nothing committed, the whole optimistic tail rewinds to the turn base.
// The editor puts the returned prompt above recalled steering and in-progress text.
test "a cancel with nothing committed rewinds the tail and returns the prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    // Prior committed content stays. The turn's tail begins at `base`.
    try session.transcript.append(.event, false, "earlier");
    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, false, "my prompt");
    try session.transcript.appendStream(.model, "partial reply");

    var prompt = try ui.Editor.Draft.fromText(gpa, "my prompt");
    session.retainTurnPrompt(&prompt, base);
    try queueSteeringText(&session, "steer");
    try session.editor.insert("typing");

    try session.reserveSteeringRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 0,
    }, 0);

    // Only the prior block survives the rewind.
    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("earlier", blocks[0].event.text.items);
    // The editor preserves chronological authorship order.
    try std.testing.expectEqualStrings("my prompt\n\nsteer\n\ntyping", session.editor.visible());
    try std.testing.expect(session.turn_origin == null);
}

// A cancel whose turn committed a round keeps that round and drops only the
// in-flight streamed tail. The prompt is committed history, so no C returns.
test "a cancel with a committed round keeps it and drops the in-flight tail" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, false, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round one") },
    });
    // The next event carries the checkpoint that committed round one. The
    // following streamed message remains outside it.
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "read"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round two partial") },
    });

    try session.reserveSteeringRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 2,
        .steering_committed_count = 0,
    }, 1);

    // The committed prompt and round stay. The in-flight message is gone.
    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].user.items);
    try std.testing.expectEqualStrings("round one", blocks[1].model.items);
    try std.testing.expectEqualStrings("", session.editor.visible());
    try std.testing.expect(session.turn_origin == null);
}

test "a final commit frontier keeps an open reply when no later event carries it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, false, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "committed answer") },
    });

    try session.reserveSteeringRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 2,
        .steering_committed_count = 0,
    }, 1);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("committed answer", blocks[1].model.items);
}

test "a partial cancel removes consumed steering beyond the commit frontier" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, false, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "committed answer") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "read"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    try queueSteeringText(&session, "restore me");
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, "restore me"),
            .count = 1,
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 4,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "uncommitted reply") },
    });

    try session.reserveSteeringRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 2,
        .steering_committed_count = 0,
    }, 1);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("committed answer", blocks[1].model.items);
    try std.testing.expectEqualStrings("restore me", session.editor.visible());
}

// A normal completion frees the retained prompt (paste payloads included), so a
// committed turn never leaks its rewind anchor.
test "a normal completion frees the retained prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const payload = "line\n" ** 15; // Collapses to an atom whose payload must be freed.
    try session.editor.paste(payload, true);
    var prompt = session.editor.detachTrimmed();
    session.retainTurnPrompt(&prompt, 0);

    try finishTurn(&session, 0);
    try std.testing.expect(session.turn_origin == null);
}
