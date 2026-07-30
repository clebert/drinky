//! The render consumer: the durable model the interface projects and the code
//! that applies events to it and paints. Owns the `Transcript`, the live-tail
//! `mode` (prompt / streaming turn / picker), the `editor`, the reconciling
//! `view`, the last laid-out dimensions, and consumer-side snapshots of usage and
//! the active model. Everything here is io-, tty-, and agent-free: producers hand
//! it `UiEvent`s and `App` drives its mutations, so the render loop can be tested
//! from a scripted event sequence without real io.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const layout = @import("layout.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");

const Session = @This();

/// Shown when a turn committed a reply the provider cut short, so a partial
/// answer is never presented as a complete one.
const truncated_notice = "response truncated at the model's output or context limit";

gpa: std.mem.Allocator,
transcript: Transcript,
editor: ui.Editor,
view: terminal.View,
/// The current interaction. Exactly one input is live: the editor while waiting
/// (`prompt`) or streaming a turn (`turn`, where it stays live for steering), or
/// a `picker`.
mode: Mode,
columns: usize,
rows: usize,
/// The model changed since the last paint; the next tick repaints and clears it.
/// The event-appliers and lifecycle methods self-mark; `App` sets it directly
/// after mutating a widget (the editor, the picker).
dirty: bool,
/// Consumer-owned copy of the agent's usage/cost, updated by `.usage` events so
/// the status gauge never reads `agent.stats` across the worker thread.
stats_shown: ai.Agent.Stats,
/// Consumer-owned copy of the active model, updated after a command runs, so
/// `paint` needs no agent for the context-window and model-name gauges.
model_shown: ai.models.Model,
/// Consumer-owned copy of the reasoning-effort level, updated after a command
/// runs, for the status-line indicator.
effort_shown: ai.llm.Effort,
/// Whether an account is active, mirrored from the agent after a command runs.
/// When false the status line shows a signed-out indicator and the model/effort
/// snapshots are stale placeholders.
signed_in: bool,
/// Steering submitted during a turn, in chronological order, as detached editor
/// drafts so recall can restore live placeholder markers. The plain queue is a
/// suffix of this list; consumed drafts remain owned until the terminal receipt
/// either drops or restores them.
steering: std.ArrayList(ui.Editor.Draft),
/// Leading drafts hidden from the compact queue view because the worker has
/// taken them — consumed into the running turn, or in flight after an Alt+Up
/// take that did not return them. Their rich drafts are never destroyed on
/// consumption, so a rolled-back batch can be recovered; the terminal receipt
/// resolves them. Always at most `steering.items.len`.
steering_retained_count: usize,
/// Leading drafts the worker has reported consuming (≤ `steering_retained_count`
/// and the source of it on consumption). Kept as a cumulative count so a delayed
/// consumed event does not double-count drafts an Alt+Up already hid.
steering_consumed_count: usize,
/// Borrowed compact `Steering:` rows — each non-retained draft's collapsed
/// visible text — rebuilt each paint so the tail gets a `[]const []const u8`
/// without a per-repaint allocation.
steering_view: std.ArrayList([]const u8),
/// The submitted prompt's rich draft, retained while a turn is live. A failed
/// or cancelled turn that committed nothing returns it to the editor; every
/// other terminal frees it because the prompt belongs to committed history.
turn_origin: ?TurnOrigin,

const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
};

/// A streaming turn: the input-border activity tick and the tool calls currently
/// running, each shown as its own box in the live tail.
const Turn = struct {
    generation: u64,
    /// Last worker progress event applied for this generation.
    progress_sequence_applied: u64,
    /// Worker progress frontier mirrored by `transcript_checkpoint`.
    progress_sequence_checkpoint: u64,
    /// Transcript length after the newest applied event known to be committed.
    transcript_checkpoint: usize,
    activity_tick: u64,
    tools: std.ArrayList(ActiveTool),
    /// `tools`' box text, rebuilt each frame so the tail gets a
    /// `[]const []const u8` without a fresh allocation per repaint.
    box_view: std.ArrayList([]const u8),

    fn boxes(self: *Turn, gpa: std.mem.Allocator) ![]const []const u8 {
        self.box_view.clearRetainingCapacity();
        for (self.tools.items) |tool| try self.box_view.append(gpa, tool.box);
        return self.box_view.items;
    }
};

/// One running tool call: its blue box shows in the live tail; `name` matches the
/// result to it and `input_json` labels that result. `box` is the box text
/// (`name input_json`). All owned, freed on completion.
const ActiveTool = struct { name: []const u8, input_json: []const u8, box: []const u8 };

const Picking = struct {
    picker: ui.Picker,
    /// Selection handler called with the chosen row when the picker is confirmed.
    select: *const fn (*ai.command.Context, usize) anyerror!ai.command.Outcome,
};

/// The retained prompt draft for a live turn.
const TurnOrigin = struct {
    prompt: ui.Editor.Draft,
};

/// A turn worker's message to the render consumer, tagged with the generation it
/// belongs to. Every payload owns its bytes until the consumer frees it.
pub const TurnEvent = struct {
    generation: u64,
    /// Monotonic within one worker. Zero is reserved for direct model tests that
    /// do not exercise the cross-thread commit frontier.
    progress_sequence: u64 = 0,
    /// Events through this sequence were committed before this event was sent.
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
        /// turn as one combined message: show it and hide those rows from the
        /// queue view, retaining their rich drafts until the receipt resolves them.
        steering_consumed: SteeringConsumed,
        /// Payload-free wakeup indicating that the authoritative worker result
        /// is ready to join.
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
/// carry a generation; input and presentation-control events do not.
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

/// Build an empty session at the default terminal size, painting through `writer`
/// and showing `model` and `effort` until a command changes them. Infallible: the
/// components own no resources until used.
pub fn init(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    model: ai.models.Model,
    effort: ai.llm.Effort,
) Session {
    return .{
        .gpa = gpa,
        .transcript = Transcript.init(gpa),
        .editor = ui.Editor.init(gpa),
        .view = terminal.View.init(gpa, writer),
        .mode = .prompt,
        .columns = 80,
        .rows = 24,
        .dirty = false,
        .stats_shown = .{},
        .model_shown = model,
        .effort_shown = effort,
        .signed_in = true,
        .steering = .empty,
        .steering_retained_count = 0,
        .steering_consumed_count = 0,
        .steering_view = .empty,
        .turn_origin = null,
    };
}

pub fn deinit(self: *Session) void {
    self.deinitMode();
    self.clearSteering();
    self.steering.deinit(self.gpa);
    self.steering_view.deinit(self.gpa);
    self.transcript.deinit();
    self.view.deinit();
    self.editor.deinit();
}

/// Clear the visible conversation and its usage and steering snapshots.
/// Commands run only in prompt mode, so no live turn state can be discarded.
pub fn resetConversation(self: *Session) void {
    std.debug.assert(self.mode == .prompt);
    self.transcript.truncate(0);
    self.stats_shown = .{};
    self.clearSteering();
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
    }
}

/// Apply one turn worker event to the model, marking it dirty and freeing the
/// event's bytes. Applying never paints. An event is dropped unless its captured
/// generation is still the active turn.
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
            // retain the rich drafts: a consumed batch can still be rolled back
            // (until its following reply commits), so the receipt — not this
            // event — decides whether each draft is dropped or recovered.
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
    if (event.progress_sequence != 0)
        turn.progress_sequence_applied = event.progress_sequence;
    return false;
}

/// Apply progress taken directly from the shared queue after its worker has been
/// joined for cancellation. An earlier event can already belong to the consumer's
/// current batch, so a sequence gap is an allowed presentation gap: discard this
/// and every later queued event rather than applying progress out of order.
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

/// Record a finished tool call in the transcript: the tool's summary (or its first
/// output line, when it gave none) beside the box it closes, then free that box.
fn applyToolResult(self: *Session, result: TurnEvent.Payload.ToolResult) !void {
    const detail = result.summary orelse first: {
        const line_end = std.mem.indexOfScalar(u8, result.content, '\n') orelse result.content.len;
        break :first result.content[0..line_end];
    };
    const finished = if (self.activeTurn()) |turn| takeTool(turn, result.name) else null;
    defer if (finished) |*tool| self.freeTool(tool);
    const arguments = if (finished) |tool| tool.input_json else "";
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}\n→ {s}", .{
        result.name,
        arguments,
        detail,
    });
    defer self.gpa.free(text);
    try self.transcript.append(.tool_result, result.is_error, text);
}

/// Apply a command outcome to the model: show its feedback or open its picker.
pub fn applyOutcome(self: *Session, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .feedback => |feedback| {
            defer self.gpa.free(feedback.content);
            try self.transcript.append(.feedback, feedback.is_error, feedback.content);
        },
        .pick => |pick| try self.openPicker(pick),
        // The app intercepts prompt, account, and conversation actions (they
        // need I/O, the tty, or the agent); they never reach the io-free session.
        .prompt, .login, .logout, .switch_account, .new_conversation => unreachable,
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
    // Init succeeded and now owns the options; drop whatever the previous mode
    // held before replacing it, so opening a picker over a live turn or picker
    // cannot leak.
    self.deinitMode();
    self.mode = .{ .picking = .{ .picker = picker, .select = pick.select } };
}

/// Leave picker mode, freeing the picker; a no-op in any other mode.
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

/// Close the picker and record the cancellation.
pub fn cancelPicker(self: *Session) !void {
    self.closePicker();
    try self.transcript.append(.feedback, false, "cancelled");
}

/// Reserve capacity for one more queued steering draft, so `App.submitSteering`'s
/// channel push becomes the only fallible step before the draft moves in — once
/// reserved, `commitSteeringDraft` cannot fail, so the worker never owns a message
/// the mirror lacks a recovery draft for.
pub fn reserveSteering(self: *Session) !void {
    try self.steering.ensureUnusedCapacity(self.gpa, 1);
}

/// Move a detached steering draft into the mirror; infallible after
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
/// checkpoint, so an abnormal exit that commits nothing can return the prompt.
/// Takes ownership of `prompt`, leaving it empty.
pub fn retainTurnPrompt(self: *Session, prompt: *ui.Editor.Draft, transcript_base: usize) void {
    std.debug.assert(self.turn_origin == null);
    const turn = self.activeTurn() orelse unreachable;
    std.debug.assert(transcript_base <= self.transcript.blocks().len);
    turn.transcript_checkpoint = transcript_base;
    self.turn_origin = .{ .prompt = prompt.* };
    prompt.* = .empty;
}

/// Drop the live turn's rewind anchor, freeing the retained prompt draft after
/// it has either entered committed history or moved back into the editor.
fn dropTurnOrigin(self: *Session) void {
    if (self.turn_origin) |*origin| {
        origin.prompt.deinit(self.gpa);
        self.turn_origin = null;
    }
}

/// Preflight editor capacity to put the returned prompt and every uncommitted
/// steering draft above the in-progress line, so abnormal receipt reconciliation
/// cannot fail. The prompt is reserved before the receipt says whether it will
/// return, so a partial commit intentionally over-reserves.
pub fn reserveSteeringRestore(self: *Session) !void {
    const lead: ?*const ui.Editor.Draft =
        if (self.turn_origin) |*origin| &origin.prompt else null;
    try self.editor.reserveComposition(lead, self.steering.items);
}

/// Preflight only the drafts a known failed receipt will restore, avoiding
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

/// Drop every steering draft, freeing its atoms.
pub fn clearSteering(self: *Session) void {
    for (self.steering.items) |*draft| draft.deinit(self.gpa);
    self.steering.clearRetainingCapacity();
    self.steering_retained_count = 0;
    self.steering_consumed_count = 0;
    self.dirty = true;
}

/// Borrowed compact `Steering:` rows: each non-retained draft's collapsed visible
/// text, rebuilt each paint without a per-frame allocation. Borrows stay valid
/// only until the mirror next mutates.
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
    try self.transcript.append(.feedback, false, "cancelled");
}

/// Apply a completed turn's receipt, append any cutoff notice, and end it. Late
/// steering remains pending so the app can promote it into a successor turn.
pub fn endTurnWithReceipt(self: *Session, receipt: *const ai.Agent.Receipt) !void {
    self.applyReceiptNormal(receipt);
    self.dropTurnOrigin();
    if (receipt.truncated) try self.transcript.append(.feedback, false, truncated_notice);
    self.transcript.endMessage();
    self.endTurn();
}

/// Rewind a failed turn to committed history, return every uncommitted draft,
/// append its feedback, and end it. Infallible after `reserveFailureRestore`
/// until the feedback append. Borrows `error_text`; the caller frees it.
pub fn failTurnWithReceipt(
    self: *Session,
    receipt: *const ai.Agent.Receipt,
    error_text: ?[]const u8,
) !void {
    self.reconcileAbnormalReceipt(receipt);
    if (receipt.truncated) try self.transcript.append(.feedback, false, truncated_notice);
    if (error_text) |text| try self.transcript.append(.feedback, true, text);
    self.transcript.endMessage();
    self.endTurn();
}

/// Resolve the rich steering mirror on a completed terminal: drop the committed
/// prefix (now in history) and make every remaining draft pending again, so
/// late-steering handling can start it as a new turn. Infallible.
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
        // No later event carried the final frontier, but every event through it
        // was applied. When committed progress is missing, keep the older
        // checkpoint: the gap could contain a stream reset that invalidates the
        // currently displayed attempt.
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

/// Free the finished turn's tool state and return to waiting for input.
pub fn endTurn(self: *Session) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
    self.dropTurnOrigin();
    self.mode = .prompt;
}

/// Assemble the visible scene from the model and project it at `size`, recording
/// it as the last laid-out dimensions. No tty or agent, so the consumer can be
/// driven from a scripted event sequence in tests.
pub fn paint(self: *Session, size: terminal.View.Size) !void {
    self.columns = size.columns;
    self.rows = size.rows;
    const status: ui.status.Info = .{
        .last = self.stats_shown.last,
        .cost = self.stats_shown.cost,
        .saved = self.stats_shown.saved,
        .context_window = self.model_shown.context_window,
        .model = self.model_shown.name,
        .effort = @tagName(self.effort_shown),
        .signed_in = self.signed_in,
        .quota = self.stats_shown.quota,
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
                .activity_tick = turn.activity_tick,
                .steering = try self.steeringView(),
                .editor = &self.editor,
            } };
        },
        .picking => |*picking| picking: {
            picking.picker.reflow(size);
            break :picking .{ .picking = &picking.picker };
        },
    };
    const scene: layout.Scene = .{
        .transcript = self.transcript.blocks(),
        .tail = tail,
        .status = &status,
    };
    try layout.project(&self.view, size, &scene);
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
        activity_changed = ui.paint.activityChanged(turn.activity_tick, &.{
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
/// the strings; on any failure here nothing is retained.
fn pushTool(turn: *Turn, gpa: std.mem.Allocator, tool: *const TurnEvent.Payload.Tool) !void {
    const box = try std.fmt.allocPrint(gpa, "{s} {s}", .{ tool.name, tool.input_json });
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
    try std.testing.expectEqualStrings("\u{200B}[paste #1 +11 lines]\u{200B}", editor.visible());

    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: ui.paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[paste #1 +11 lines]") != null);

    // It expands back to the exact bytes for a send boundary.
    const expanded = try editor.expanded(.whole_prompt);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

// The consumer seam without real io: a scripted turn's worker events drive the
// transcript, usage, and turn teardown; applying marks dirty but never paints;
// one paint then renders the coalesced frame.
test "scripted stream events drive the model and one coalesced paint" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    // Owned payloads, exactly as a producer task would allocate them.
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

    // Applying marks the model dirty but paints nothing.
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
        .summary = try gpa.dupe(u8, "3 lines · 27 B"),
        .is_error = false,
    } });
    try finishTurn(&session, 0);
    try session.paint(.{ .columns = 80, .rows = 24 });

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "3 lines · 27 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "line one") == null);
}

// A cut-off answer is committed history, so the turn's end says it is partial
// rather than letting it read as a complete reply.
test "a truncated receipt appends a notice after the answer" {
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
    try std.testing.expect(!blocks[1].feedback.is_error);
    try std.testing.expectEqualStrings(truncated_notice, blocks[1].feedback.text.items);

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
    try std.testing.expectEqualStrings(truncated_notice, after[2].feedback.text.items);
    try std.testing.expect(after[3].feedback.is_error);
    try std.testing.expectEqualStrings("boom", after[3].feedback.text.items);
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

// A worker event arriving after the turn ends (a straggler from a cancelled turn)
// is freed and dropped, not appended.
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
    // Three blocks: the stale error appended no feedback block either.
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

// Queued steering shows in the tail; a consumed event moves the combined text
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
    // The combined batch shows as one user block and its compact rows drop from
    // the view, but the rich drafts are retained (hidden) so a rolled-back batch
    // can still be recovered until the receipt resolves it.
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

    // The committed draft is gone; the uncommitted one returns to the editor and
    // the counts reset.
    try std.testing.expectEqual(@as(usize, 0), session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.steering_retained_count);
    try std.testing.expectEqual(@as(usize, 0), session.steering_consumed_count);
    try std.testing.expectEqualStrings("restore me", session.editor.visible());
}

// A steered large paste shows as its collapsed marker in the compact queue view,
// never its payload; the payload rides along in the rich draft for recall.
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
    try std.testing.expect(std.mem.indexOf(u8, painted, "[paste #1 +16 lines]") != null);
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
        .title = "Pick",
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

// The activity clock keeps advancing between stream events, but a corner or
// vertical cell dwells for an extra tick without repainting.
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

test "a failure with nothing committed rewinds the tail and returns the prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try session.transcript.append(.feedback, false, "earlier");
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
    try std.testing.expectEqualStrings("earlier", blocks[0].feedback.text.items);
    try std.testing.expect(blocks[1].feedback.is_error);
    try std.testing.expectEqualStrings("Overloaded", blocks[1].feedback.text.items);
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
    try std.testing.expect(blocks[2].feedback.is_error);
    try std.testing.expectEqualStrings("boom", blocks[2].feedback.text.items);
    try std.testing.expectEqualStrings("restore me", session.editor.visible());
    try std.testing.expect(session.turn_origin == null);
    try std.testing.expect(!session.hasSteering());
}

// With nothing committed, the whole optimistic tail rewinds to the turn base and
// the editor puts the returned prompt above recalled steering and in-progress text.
test "a cancel with nothing committed rewinds the tail and returns the prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    // Prior committed content stays; the turn's tail begins at `base`.
    try session.transcript.append(.feedback, false, "earlier");
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
    try std.testing.expectEqualStrings("earlier", blocks[0].feedback.text.items);
    // The editor preserves chronological authorship order.
    try std.testing.expectEqualStrings("my prompt\n\nsteer\n\ntyping", session.editor.visible());
    try std.testing.expect(session.turn_origin == null);
}

// A cancel whose turn committed a round keeps that round and drops only the
// in-flight streamed tail; the prompt is committed history, so no C returns.
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
    // The next event carries the checkpoint that committed round one, then the
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

    // The committed prompt and round stay; the in-flight message is gone.
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
