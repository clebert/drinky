//! The render consumer: the durable model the interface projects and the code
//! that applies events to it and paints. It owns the `Transcript`, the sole
//! transient notice, the interaction `mode` (prompt / streaming turn / picker /
//! read-only page), and the `editor`. It also owns the reconciling `view`, the
//! last laid-out dimensions, and consumer-side snapshots of usage, model, and
//! account. Everything here is io-, tty-, and agent-free.
//! Producers hand it `UiEvent`s and `App` drives its mutations. Tests can then
//! drive the render loop from a scripted event sequence without real io.

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

/// The row above the editor while a retry waits. It names the two keys that own
/// the retry. Enter is not one of them: it sends the editor text as a message of
/// its own, and that turn drops the retry.
const retry_hint = "Ctrl+N: Try again · Esc: Dismiss";

/// One tool call the model is still streaming. The row counts the argument bytes
/// that arrived instead of showing them, because the arguments are JSON until
/// the call commits and a row of JSON that slides tells the reader nothing. A
/// count that climbs reports the progress of a long call, and the row keeps one
/// shape while it climbs.
///
/// The row also names its phase, because a reply streams its calls one after the
/// other. A row that waits then stands still, and the phase tells the reader
/// that the call is not stuck.
///
/// The count measures what the model has produced so far, not what a tool has
/// done. A `write` that has streamed 402 bytes of arguments has written nothing
/// yet, so the row must not read as a file size.
const StreamedTool = struct {
    name: []const u8,
    bytes: usize,
    phase: Phase,
    /// The row text, rewritten whenever the count or the phase changes. This row
    /// changes only on an event, so it is built there and the frame borrows it.
    /// The timed row of `ActiveTool` changes on every frame instead, so that one
    /// is built at paint time.
    ///
    /// `Received` names the wire, never the file. It is the one count in a box
    /// that reads in bytes, because it measures a transfer in progress.
    box: std.ArrayList(u8),

    /// How far one streamed call has come. Every phase keeps the same row shape,
    /// with the name, the bytes received so far, and the phase. A count that
    /// stands still therefore still reports a state, and a reader can tell a
    /// call that receives its arguments from one that waits.
    const Phase = enum {
        /// The arguments of this call arrive now, so the count climbs. Only the
        /// newest row of a reply that still streams is in this phase.
        ///
        /// Only a new call moves a row out of this phase. A reply that streams
        /// text or thinking after a call keeps the phase until it commits, so
        /// that row can hold a count that stands still for a short time. Text
        /// must not move it, because a provider that interleaves text into an
        /// open call would then lose every fragment that follows: only a row in
        /// this phase counts.
        streaming,
        /// The arguments are complete and the call waits. The reply that holds
        /// it still streams, so a later call of the same reply can follow.
        queued,
        /// The call waits and a call of its reply already started. That reply
        /// streams nothing more, so the next streamed content drops this row.
        stale,
    };

    fn deinit(self: *StreamedTool, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.box.deinit(gpa);
    }

    fn refresh(self: *StreamedTool, gpa: std.mem.Allocator) !void {
        var scale: [16]u8 = undefined;
        self.box.clearRetainingCapacity();
        // The count comes before the phase, because a narrow window cuts the
        // tail of the row. The count is the field that reports progress, so the
        // cut must fall on the phase: a row that keeps its count alone still
        // tells a call that receives from a call that waits, by the motion of
        // the count.
        try self.box.print(gpa, "Tool: {s} · Received: {s} · Status: {s}", .{
            self.name,
            ai.format.bytes(&scale, self.bytes),
            switch (self.phase) {
                .streaming => "Streaming",
                // Both waiting phases read the same. They differ in how long the
                // row lives, not in what the call does.
                .queued, .stale => "Queued",
            },
        });
    }
};

gpa: std.mem.Allocator,
transcript: Transcript,
/// The sole transient notice. Its owned content never enters the transcript.
notice: ?ai.command.Outcome.Message,
/// The armed one-shot confirmations. A warning arms one, the key that raised it
/// passes it once, and any other user action cancels it.
confirmations: std.EnumSet(Confirmation),
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
/// The working directory the status line shows, with the home directory
/// abbreviated. It borrows `App` storage, because the working directory cannot
/// change while Drinky runs. Empty hides the whole part.
directory_shown: []const u8,
/// The repository root that `App` re-reads the head from, or null outside a
/// repository. It belongs to the place the status line shows, next to the
/// directory and the branch it produces.
branch_root: ?[]const u8,
/// The branch of the project. `App` refreshes it, and the bytes live here so
/// that `paint` needs no io. Empty outside a repository, and empty for a head
/// Drinky cannot read.
branch_buffer: [ai.project.head_name_bytes_max]u8,
branch_length: usize,
/// Steering submitted during a turn, in chronological order, as detached editor
/// drafts. Recall can then restore live placeholder markers. The plain queue is
/// a suffix of this list. Consumed drafts remain owned until the terminal
/// receipt either drops or restores them.
steering: std.ArrayList(ui.Editor.Draft),
/// Leading drafts hidden from the compact queue view because the worker has
/// taken them. A taken draft is consumed into the running turn, or in flight
/// after a Ctrl+P take that did not return it. Consumption never destroys
/// their rich drafts, so a rolled-back batch remains recoverable. The terminal
/// receipt resolves them. Always at most `steering.items.len`.
steering_retained_count: usize,
/// Leading drafts the worker has reported as consumed (≤ `steering_retained_count`
/// and the source of it on consumption). The count is cumulative, so a delayed
/// consumed event does not double-count drafts a Ctrl+P already hid.
steering_consumed_count: usize,
/// Borrowed compact `Queued message:` rows: each non-retained draft's collapsed
/// visible text. Each paint rebuilds them, so the tail gets a
/// `[]const []const u8` without a per-repaint allocation.
steering_view: std.ArrayList([]const u8),
/// The submitted prompt's rich draft, retained while a turn is live. A failed
/// or canceled turn that committed nothing returns it to the editor. Every
/// other terminal frees it because the prompt belongs to committed history.
turn_origin: ?TurnOrigin,
/// Whether a retry context waits at the prompt. `App` owns that context and
/// mirrors this bit, so the hint row above the editor names its controls.
retry_shown: bool,
/// Milliseconds on the monotonic clock, written by the driver before each paint.
/// The session does no io, so it cannot read a clock of its own. It stays zero
/// until the first paint, which makes every span it reports zero.
clock_ms: i64,
/// The wall-clock timeout a `bash` call runs under when the call names none, in
/// milliseconds. The driver copies it from the configuration.
bash_timeout_ms: u64,
/// The roots every path in a tool row is measured against. The driver copies
/// them from the resolved session. Empty roots leave every path as it is.
display_roots: ai.format.Roots,

const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
    viewing: ui.Page,
};

/// A streaming turn: the input-separator activity tick and the running tool
/// calls. Each tool call appears in its own box in the live tail.
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
    /// The blink clock of the input caret. An edit restarts it at zero.
    caret_tick: u64,
    tools: std.ArrayList(ActiveTool),
    /// The tool calls the model is still streaming, oldest first. Each shows its
    /// name, the argument bytes received so far, and its phase. A committed call
    /// replaces the oldest one, because both sides keep the order of the reply.
    streamed_tools: std.ArrayList(StreamedTool),
    /// The box of every tool call above. Each frame rebuilds it, so the tail
    /// gets a `[]const ui.paint.Box` without a fresh allocation per repaint.
    box_view: std.ArrayList(ui.paint.Box),

    fn activity(self: *const Turn) ui.paint.Activity {
        return .{
            .motion_tick = self.activity_tick,
            .progress_age_ticks = self.activity_tick -% self.progress_tick_last,
            .caret_tick = self.caret_tick,
        };
    }

    fn boxes(self: *Turn, gpa: std.mem.Allocator, now_ms: i64) ![]const ui.paint.Box {
        self.box_view.clearRetainingCapacity();
        // Every row holds one call. A committed one names what it acts on, and a
        // streamed one counts the bytes that have arrived. A call under a
        // timeout adds the row that reports its time.
        for (self.tools.items) |*tool|
            try self.box_view.append(gpa, .{ .text = try tool.text(gpa, now_ms), .fit = .head });
        for (self.streamed_tools.items) |streamed|
            try self.box_view.append(gpa, .{ .text = streamed.box.items, .fit = .head });
        return self.box_view.items;
    }
};

/// One committed call that is running now. A call under a wall-clock timeout
/// keeps a second row that reports how long it has run against how long it can
/// run, so the user can weigh a cancel. Every other call is its head row alone.
///
/// `name` matches the result to the call and `input_json` labels that result.
/// The session owns every field and frees them on completion.
const ActiveTool = struct {
    name: []const u8,
    input_json: []const u8,
    /// The head row, `Tool: {name} · {label}: {subject}`, built once when the
    /// call starts.
    box: []const u8,
    started_ms: i64,
    /// The timeout the call runs under, clamped into the legal window. Null for
    /// a tool that runs under none.
    timeout_ms: ?u64,
    /// The head row and the timed row below it, rebuilt on the frames that show
    /// it. Empty for a tool with no timeout, which paints `box` directly.
    rows: std.ArrayList(u8),

    fn deinit(self: *ActiveTool, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.input_json);
        gpa.free(self.box);
        self.rows.deinit(gpa);
    }

    /// The text of this call's box at `now_ms`. A call under a timeout rebuilds
    /// its two rows, because the time it has run changes between frames.
    fn text(self: *ActiveTool, gpa: std.mem.Allocator, now_ms: i64) ![]const u8 {
        const timeout_ms = self.timeout_ms orelse return self.box;
        var elapsed: [24]u8 = undefined;
        var allowed: [24]u8 = undefined;
        // Every timeout arrives clamped, so it always fits a signed span and the
        // row always names a real wait.
        const limit = ai.format.duration(&allowed, @intCast(timeout_ms));
        self.rows.clearRetainingCapacity();
        // `Time` names the same measure the finished box reports, so a call does
        // not rename its own run time when it ends.
        try self.rows.print(gpa, "{s}\nTime: {s} · Timeout: {s}", .{
            self.box,
            ai.format.duration(&elapsed, now_ms - self.started_ms),
            limit,
        });
        return self.rows.items;
    }
};

const Picking = struct {
    picker: ui.Picker,
    /// The command handler a confirmed row goes to.
    select: *const fn (*ai.command.Context, usize) anyerror!ai.command.Outcome,
    /// The borrowed sentence that identifies the canceled selection.
    cancellation_message: []const u8,
};

/// The retained prompt draft for a live turn.
const TurnOrigin = struct {
    prompt: ui.Editor.Draft,
};

/// The one-shot confirmations. Each names a warning that one repeat of its own
/// key passes. The guards differ on purpose: a draft signals that the user
/// types, so a key that a reflex can hit while typing warns first. Ctrl+D means
/// leave this layer and nothing else, so it warns only where it destroys the
/// draft, and Ctrl+C clears without a warning because the clear is its purpose.
pub const Confirmation = enum {
    /// One unchanged Enter sends a refused command line to the model as typed.
    /// The prompt sends it as a message, and a turn queues it as steering. The
    /// row that named the offer goes with the confirmation: a key cancels both
    /// in the app, a turn end in `endTurn`, and a later notice in `setNotice`.
    /// A row that outlives its offer asks for an Enter that does nothing.
    message,
    /// One more Esc cancels the running turn. The first Esc with a draft arms
    /// it, because a reflex Esc while the user types can mean a dismiss or a
    /// clear. An Esc over an empty editor is a decision and cancels at once.
    turn_cancel,
    /// One more Ctrl+D quits over a draft. The first Ctrl+D with a draft arms
    /// it, because the quit discards the draft.
    quit,
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
        /// Display only: the model opened a tool call with this name. Its
        /// arguments follow as `tool_arguments` fragments.
        tool_name: []u8,
        /// Display only: one fragment of the open tool call's arguments.
        tool_arguments: []u8,
        tool_start: Tool,
        tool_result: ToolResult,
        usage: ai.Agent.Stats,
        /// A retry is about to re-stream the reply: drop the partial text shown so
        /// far so the retried attempt starts clean.
        stream_reset,
        /// The provider answered with another model than the request named. The
        /// consumer records a durable event, so the switch stays visible in the
        /// history instead of passing as the requested model's reply.
        model_mismatch: ModelMismatch,
        /// The worker folded `count` queued steering messages into the running
        /// turn as one combined message: show it, hide those rows from the queue
        /// view, and retain their rich drafts until the receipt resolves them.
        steering_consumed: SteeringConsumed,
        /// Drinky sent one skill file into the running turn, because a tool met a
        /// file that a rule guards. It is no message of the user, so it shows as
        /// a head line rather than a user box.
        skill_loaded: SkillLoaded,
        /// Payload-free wakeup: the authoritative worker result is ready to join.
        turn_ended,

        pub const Tool = struct { name: []u8, input_json: []u8 };
        /// One finished call, as the interface shows it. The model reads the
        /// output, so the event carries the box line alone.
        pub const ToolResult = struct {
            name: []u8,
            /// The box line the tool decided, with the shape it decided for it.
            /// The event owns the text.
            summary: ?ai.tool.Result.Summary = null,
            is_error: bool,
        };
        pub const SteeringConsumed = struct { text: []u8, count: usize };
        /// The name and the file of one skill that Drinky sent. The event owns
        /// both.
        pub const SkillLoaded = struct { skill: []u8, source: []u8 };
        /// The requested and the served model name of one switched reply. The
        /// event owns both, and the named fields keep the two apart.
        pub const ModelMismatch = struct { requested: []u8, served: []u8 };
    };

    pub fn deinit(self: *const TurnEvent, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .text, .thinking, .tool_name, .tool_arguments => |bytes| gpa.free(bytes),
            .tool_start => |tool| {
                gpa.free(tool.name);
                gpa.free(tool.input_json);
            },
            .tool_result => |result| {
                gpa.free(result.name);
                if (result.summary) |summary| gpa.free(summary.text);
            },
            .steering_consumed => |consumed| gpa.free(consumed.text),
            .skill_loaded => |loaded| {
                gpa.free(loaded.skill);
                gpa.free(loaded.source);
            },
            .model_mismatch => |mismatch| {
                gpa.free(mismatch.requested);
                gpa.free(mismatch.served);
            },
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

/// Build an empty session. It paints through `writer` and shows `model` and
/// `effort` until a command changes them.
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
        .confirmations = .initEmpty(),
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
        .directory_shown = "",
        .branch_root = null,
        .branch_buffer = undefined,
        .branch_length = 0,
        .steering = .empty,
        .steering_retained_count = 0,
        .steering_consumed_count = 0,
        .steering_view = .empty,
        .turn_origin = null,
        .retry_shown = false,
        .clock_ms = 0,
        .bash_timeout_ms = (ai.tool.Context.Bash{}).timeout_ms,
        .display_roots = .{},
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

/// Clear the visible conversation and its usage and steering snapshots. Commands
/// run only in prompt mode, so the reset cannot discard live turn state. The next
/// paint resets the screen, so no row of the cleared conversation stays in the
/// terminal scrollback.
pub fn resetConversation(self: *Session) void {
    std.debug.assert(self.mode == .prompt);
    self.transcript.truncate(0);
    self.clearNotice();
    self.confirmations = .initEmpty();
    self.stats_shown = .{};
    self.clearSteering();
    self.view.resetScreen();
    self.dirty = true;
}

/// Clear the transient notice. The regular footer returns on the next frame.
pub fn clearNotice(self: *Session) void {
    if (self.notice) |notice| {
        self.gpa.free(notice.content);
        self.notice = null;
        self.dirty = true;
    }
}

/// Arm `confirmation`, so one repeat of its key passes its warning. The modes
/// that can arm one are the modes whose key raises its warning.
pub fn armConfirmation(self: *Session, confirmation: Confirmation) void {
    switch (confirmation) {
        .quit => std.debug.assert(self.mode == .prompt),
        .message => std.debug.assert(self.mode == .prompt or self.mode == .turn),
        .turn_cancel => std.debug.assert(self.mode == .turn),
    }
    self.confirmations.insert(confirmation);
}

/// Cancel `confirmation` after any user action other than its own key.
pub fn cancelConfirmation(self: *Session, confirmation: Confirmation) void {
    self.confirmations.remove(confirmation);
}

/// Consume `confirmation` and return whether it was armed.
pub fn takeConfirmation(self: *Session, confirmation: Confirmation) bool {
    const confirmed = self.confirmations.contains(confirmation);
    self.confirmations.remove(confirmation);
    return confirmed;
}

/// Replace the transient notice and take ownership of `notice.content`. The new row
/// replaces the row that named a send-as-a-message offer, so the offer goes with it.
/// Every caller that arms one arms after it reports its row, so this drop never eats
/// the offer that belongs to the new row.
///
/// A notice that a caller raises while a turn runs must name that turn, because
/// `endTurn` clears the footer. Today only a key raises one there. A writer that
/// reports from an event instead must first give `endTurn` a rule to keep it.
fn setNotice(self: *Session, notice: ai.command.Outcome.Message) void {
    self.cancelConfirmation(.message);
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
        .text => |delta| {
            self.dropStaleTools(turn);
            try self.transcript.appendStream(.model, delta);
        },
        .thinking => |delta| {
            self.dropStaleTools(turn);
            try self.transcript.appendStream(.thinking, delta);
        },
        .tool_name => |name| {
            self.dropStaleTools(turn);
            try self.openStreamedTool(turn, name);
        },
        .tool_arguments => |delta| try self.growStreamedTool(turn, delta),
        .tool_start => |*tool| {
            self.transcript.endMessage();
            try self.pushTool(turn, tool);
            // One committed call replaces its own streamed row. A sibling call
            // of the same reply keeps its row while this one runs.
            try self.dropStreamedTool(turn, tool.name);
        },
        .tool_result => |result| try self.applyToolResult(result),
        .usage => |stats| self.stats_shown = stats,
        .stream_reset => {
            self.transcript.discardMessage();
            self.clearStreamedTools(turn);
        },
        .model_mismatch => |mismatch| {
            // A durable event block, so the switch survives in the history the
            // way a login or a model change does. The append ends the open
            // streamed message, so a later stream reset could not discard the
            // partial text. The agent therefore reports a mismatch only for a
            // committed reply, and no producer can emit one mid-stream.
            const text = try std.fmt.allocPrint(
                self.gpa,
                "The provider answered with the model \"{s}\" instead of the requested " ++
                    "model \"{s}\".",
                .{ mismatch.served, mismatch.requested },
            );
            defer self.gpa.free(text);
            try self.transcript.append(.event, .{ .is_error = true }, text);
        },
        .steering_consumed => |consumed| {
            // Show the folded batch and hide its rows from the queue view, but
            // retain the rich drafts: a consumed batch can still roll back
            // (until its following reply commits). The receipt — not this
            // event — decides whether to drop or recover each draft.
            try self.transcript.append(.user, .{}, consumed.text);
            // Advance the consumed frontier, then the view frontier to cover it,
            // without double-counting drafts an earlier Ctrl+P already hid.
            self.steering_consumed_count =
                @min(self.steering_consumed_count + consumed.count, self.steering.items.len);
            self.steering_retained_count =
                @max(self.steering_retained_count, self.steering_consumed_count);
        },
        .skill_loaded => |loaded| {
            // The head reads like the head of a `/skill:name` line and takes no
            // box, because the user typed none of it. The skill file itself
            // stays out of the transcript, as an invoked skill does.
            const source = try ai.format.path(self.gpa, loaded.source, &self.display_roots);
            defer self.gpa.free(source);
            const text = try std.fmt.allocPrint(
                self.gpa,
                "Skill: {s} · File: {s}",
                .{ loaded.skill, source },
            );
            defer self.gpa.free(text);
            try self.transcript.append(.skill, .{}, text);
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

/// Record a finished tool call in the transcript: the line the tool decided,
/// beside the box it closes. Then free that box. The tool owns that decision, so
/// a result without one leaves the call row alone.
fn applyToolResult(self: *Session, result: TurnEvent.Payload.ToolResult) !void {
    var finished = if (self.activeTurn()) |turn| takeTool(turn, result.name) else null;
    defer if (finished) |*tool| tool.deinit(self.gpa);
    // The running call already built this head row, so the permanent block
    // borrows it rather than reading the arguments a second time. Only a result
    // whose call is gone has to build one.
    if (finished) |tool| return self.appendToolBlock(&.{
        .head = tool.box,
        .detail = result.summary,
        .is_error = result.is_error,
    });
    const head = try toolRow(self.gpa, result.name, &.{
        .label = "",
        .subject = "",
        .timeout_ms = null,
    });
    defer self.gpa.free(head);
    try self.appendToolBlock(&.{
        .head = head,
        .detail = result.summary,
        .is_error = result.is_error,
    });
}

/// One permanent tool block: the call row, and the line below it. Both are
/// borrowed text, so they take named fields and a call site cannot mix them up.
const ToolBlock = struct {
    /// The call row: the tool and what it acts on. Every block keeps it, so the
    /// history shows that the call happened.
    head: []const u8,
    /// The result row below it, with the shape that decides how the box shows
    /// it. Null when the tool decided that the call needs no second row. The
    /// text is borrowed.
    detail: ?ai.tool.Result.Summary,
    is_error: bool,
};

/// Append one permanent tool block: the call above its result detail. A block
/// without a detail is the call row alone.
///
/// A detail of measures carries its own keys, so a `Result` key in front of it
/// only labels a label and spends columns the row truncates. A line such as
/// `Exit code: 1` names its own state too, so a failure that states measures
/// takes no prefix either.
///
/// The sentence of a failure takes `Error`, which names the severity the way
/// every other failure line in the interface does and survives a terminal copy
/// after the color of the box is gone. That sentence also wraps, because its
/// instruction sits at the end.
fn appendToolBlock(self: *Session, block: *const ToolBlock) !void {
    const detail = block.detail orelse
        return self.transcript.append(.tool_result, .{ .is_error = block.is_error }, block.head);
    const sentence = detail.kind == .sentence;
    const options: ui.block.Entry.Options = .{
        .is_error = block.is_error,
        .fit = if (sentence) .wrap else .head,
    };
    const text = if (sentence and block.is_error)
        try std.fmt.allocPrint(self.gpa, "{s}\nError: {s}", .{ block.head, detail.text })
    else
        try std.fmt.allocPrint(self.gpa, "{s}\n{s}", .{ block.head, detail.text });
    defer self.gpa.free(text);
    try self.transcript.append(.tool_result, options, text);
}

/// Apply a command outcome to the model: replace its notice, record its event,
/// open its picker, or write its line into the editor.
pub fn applyOutcome(self: *Session, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        // A refusal is a notice whose line stays in the editor. The app owns that
        // rule, because the session never clears the editor for a command.
        .notice, .refusal => |message| self.setNotice(message),
        .event => |event| {
            defer self.gpa.free(event.content);
            try self.transcript.append(
                .event,
                .{ .is_error = event.severity == .failure },
                event.content,
            );
        },
        .pick => |*pick| try self.openPicker(pick),
        // A picked line that takes an argument replaces the draft, so the user
        // completes it and sends it. The command that opened the picker already
        // cleared the editor, so nothing of the typed line survives here.
        .editor_text => |text| {
            defer self.gpa.free(text);
            self.editor.clear();
            try self.editor.insert(text);
            self.markEdited();
        },
        // The app intercepts prompt, account, conversation, and inspection
        // actions. They never reach the io-free session.
        .prompt,
        .login,
        .logout,
        .switch_account,
        .new_conversation,
        .show_system_prompt,
        .show_colors,
        => unreachable,
    }
    self.dirty = true;
}

/// Enter picker mode over `pick`, whose confirmation goes to `pick.select`. Takes
/// ownership of `pick.options`.
fn openPicker(self: *Session, pick: *const ai.command.Outcome.Pick) !void {
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
    self.markEdited();
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
    self.markEdited();
}

/// Set the live turn's initial transcript checkpoint, so an abnormal exit that
/// commits nothing removes the blocks that the turn appended. A turn whose request
/// never sat in the editor, such as a retry that Ctrl+N sent, needs this alone.
pub fn markTurnBase(self: *Session, transcript_base: usize) void {
    const turn = self.activeTurn() orelse unreachable;
    std.debug.assert(transcript_base <= self.transcript.blocks().len);
    turn.transcript_checkpoint = transcript_base;
}

/// Retain the submitted prompt's rich draft and set the turn's initial transcript
/// checkpoint. An abnormal exit that commits nothing can then return the prompt.
/// Takes ownership of `prompt` and leaves it empty.
pub fn retainTurnPrompt(self: *Session, prompt: *ui.Editor.Draft, transcript_base: usize) void {
    std.debug.assert(self.turn_origin == null);
    self.markTurnBase(transcript_base);
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

/// Close any open model run, then enter turn mode with fresh separator activity
/// and no active tools.
pub fn beginTurn(self: *Session, generation: u64) void {
    self.transcript.endMessage();
    self.confirmations = .initEmpty();
    self.mode = .{ .turn = .{
        .generation = generation,
        .progress_sequence_applied = 0,
        .progress_sequence_checkpoint = 0,
        .transcript_checkpoint = self.transcript.blocks().len,
        .activity_tick = 0,
        .progress_tick_last = 0,
        .caret_tick = 0,
        .tools = .empty,
        .streamed_tools = .empty,
        .box_view = .empty,
    } };
    self.dirty = true;
}

/// Move every running tool call into the transcript as a failed block, oldest
/// first, and empty the chrome. The agent commits one error result per call
/// before it dispatches the call, so a block that never arrives hides work that
/// the next request carries. Each block takes the wording of that committed
/// result. A block that cannot allocate loses its call. The flush still covers
/// the calls after it and returns the first error.
fn flushRunningTools(self: *Session) ?anyerror {
    const turn = self.activeTurn() orelse return null;
    var maybe_error: ?anyerror = null;
    for (turn.tools.items) |*tool| {
        self.appendToolBlock(&.{
            .head = tool.box,
            .detail = .{ .text = ai.Agent.unfinished_tool_result, .kind = .sentence },
            .is_error = true,
        }) catch |err| {
            if (maybe_error == null) maybe_error = err;
        };
        tool.deinit(self.gpa);
    }
    turn.tools.clearRetainingCapacity();
    return maybe_error;
}

/// Abort the running turn's model state: close the open run, fail every running
/// tool call, drop the turn's chrome, and record the cancellation. The io-side
/// worker teardown is the caller's.
pub fn abortTurn(self: *Session) !void {
    // The flush runs before the chrome goes, but a lost block must not hide the
    // cancellation, so its error waits for the event.
    const maybe_flush_error = self.flushRunningTools();
    self.endTurn();
    self.dirty = true;
    try self.transcript.append(.event, .{}, "You canceled the turn.");
    if (maybe_flush_error) |flush_error| return flush_error;
}

/// Apply a completed turn's receipt, append any cutoff event, and end it. Late
/// steering remains pending so the app can promote it into a successor turn.
pub fn endTurnWithReceipt(self: *Session, receipt: *const ai.Agent.Receipt) !void {
    self.applyReceiptNormal(receipt);
    self.dropTurnOrigin();
    if (receipt.truncated) try self.transcript.append(.event, .{}, truncated_event);
    self.transcript.endMessage();
    self.endTurn();
}

/// Rewind a failed turn to committed history, return every uncommitted draft,
/// fail every running tool call, append its event, and end it. Infallible after
/// `reserveFailureRestore` until the tool blocks. Borrows `error_text`. The
/// caller frees it.
pub fn failTurnWithReceipt(
    self: *Session,
    receipt: *const ai.Agent.Receipt,
    error_text: ?[]const u8,
) !void {
    self.reconcileAbnormalReceipt(receipt);
    // The flush runs before the chrome goes, but a lost block must not hide the
    // failure, so its error waits for the event.
    const maybe_flush_error = self.flushRunningTools();
    if (receipt.truncated) try self.transcript.append(.event, .{}, truncated_event);
    if (error_text) |text| try self.transcript.append(.event, .{ .is_error = true }, text);
    self.transcript.endMessage();
    self.endTurn();
    if (maybe_flush_error) |flush_error| return flush_error;
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

/// Show `name` as the branch of the project. An empty name, or one longer than
/// the buffer, leaves the status line with the directory alone. `App` reads the
/// name, so the copy keeps `paint` free of io.
pub fn setBranch(self: *Session, name: []const u8) void {
    const value = if (name.len > self.branch_buffer.len) "" else name;
    if (std.mem.eql(u8, self.branch_buffer[0..self.branch_length], value)) return;
    @memcpy(self.branch_buffer[0..value.len], value);
    self.branch_length = value.len;
    self.dirty = true;
}

/// The branch of the project, or null when Drinky found none.
pub fn branch(self: *const Session) ?[]const u8 {
    if (self.branch_length == 0) return null;
    return self.branch_buffer[0..self.branch_length];
}

/// Free the finished turn's tool state and return to prompt mode. The end of a turn
/// is no key event, so it must clear the footer and the one-shot offers here. Only
/// a key that arrives during the turn can put a notice on the screen, and every
/// such notice names that turn: the offer to queue a refused line, the restriction
/// on a command that a turn cannot host, and the warning that one more Esc cancels
/// the turn. None of them is true afterward.
///
/// The refused line stays in the editor. The next Enter reports the state that the
/// prompt has.
pub fn endTurn(self: *Session) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
    self.dropTurnOrigin();
    self.clearNotice();
    self.confirmations = .initEmpty();
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
        .directory = self.directory_shown,
        .branch = self.branch(),
        .context_tokens = self.stats_shown.context_tokens,
        .cache_usage = self.stats_shown.cache_usage,
        .cost = self.stats_shown.cost,
        .context_window = self.model_shown.context_window,
        .model = self.model_shown.name,
        .effort = @tagName(self.effort_shown),
        .account = self.account_shown,
        .quota = self.stats_shown.quota,
        .notice = if (self.notice) |notice| .{
            .text = notice.content,
            .severity = notice.severity,
        } else null,
    };

    const tail: layout.Tail = switch (self.mode) {
        .prompt => prompt: {
            self.editor.reflow(size);
            break :prompt .{ .prompt = .{
                .hint = if (self.retry_shown) retry_hint else null,
                .editor = &self.editor,
            } };
        },
        .turn => |*turn| turn: {
            self.editor.reflow(size);
            break :turn .{ .turn = .{
                .tools = try turn.boxes(self.gpa, self.clock_ms),
                .activity = turn.activity(),
                .steering = try self.steeringView(),
                .editor = &self.editor,
            } };
        },
        .picking => |*picking| picking: {
            try picking.picker.reflow(size);
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
/// shell prompt does not overwrite the input area and status line after exit.
pub fn parkCursor(self: *Session) !void {
    try self.view.parkCursor();
}

/// Record a change of the input: repaint and restart the caret blink. The caret
/// then stays visible while the user types into a running turn. `App` calls this
/// after it edits the live editor.
pub fn markEdited(self: *Session) void {
    self.dirty = true;
    if (self.activeTurn()) |turn| turn.caret_tick = 0;
}

/// Advance the activity clock and report whether this tick repaints. A turn
/// advances without marking the model dirty, so motion continues between model
/// events. The caret blink shares the clock, so a blink flip also repaints.
pub fn advanceFrame(self: *Session) bool {
    var activity_changed = false;
    if (self.activeTurn()) |turn| {
        turn.activity_tick +%= 1;
        turn.caret_tick +%= 1;
        const activity = turn.activity();
        activity_changed = ui.paint.activityChanged(&activity, self.columns);
    }
    return self.dirty or activity_changed;
}

/// Whether a component wants continuous frames: the active turn's separators.
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

/// The head row of one committed call: the tool and what it acts on, as a key
/// and a value like every other fragment Drinky shows. The key also says which
/// kind of value follows, because a file and a pattern read alike on their own.
/// A call with no subject is its name alone, so the row carries no dangling
/// separator.
fn toolRow(gpa: std.mem.Allocator, name: []const u8, call: *const ai.tool.Call) ![]u8 {
    if (call.subject.len == 0) return std.fmt.allocPrint(gpa, "Tool: {s}", .{name});
    return std.fmt.allocPrint(gpa, "Tool: {s} · {s}: {s}", .{ name, call.label, call.subject });
}

/// Allocate a running tool call's owned strings and record it on `turn`. Ends at
/// a committed append so a later fallible repaint can never orphan or double-free
/// the strings. A failure here retains nothing.
fn pushTool(self: *Session, turn: *Turn, tool: *const TurnEvent.Payload.Tool) !void {
    const gpa = self.gpa;
    // One read of the arguments serves the row and the timeout below it.
    const call = try ai.tool.describe(
        gpa,
        tool.name,
        tool.input_json,
        &self.display_roots,
        self.bash_timeout_ms,
    );
    defer call.deinit(gpa);
    const box = try toolRow(gpa, tool.name, &call);
    errdefer gpa.free(box);
    const name_copy = try gpa.dupe(u8, tool.name);
    errdefer gpa.free(name_copy);
    const arguments = try gpa.dupe(u8, tool.input_json);
    errdefer gpa.free(arguments);
    try turn.tools.append(gpa, .{
        .name = name_copy,
        .input_json = arguments,
        .box = box,
        // The clock of the last frame, so a call cannot report a start that the
        // interface has not shown yet.
        .started_ms = self.clock_ms,
        .timeout_ms = call.timeout_ms,
        .rows = .empty,
    });
}

/// Open the row of a tool call the model started to stream. It counts from zero,
/// so a call with no arguments yet still shows that it started.
///
/// A reply streams one call at a time, so the row above stops counting here. It
/// moves to the queued phase, because the count it holds is now final.
fn openStreamedTool(self: *Session, turn: *Turn, name: []const u8) !void {
    if (turn.streamed_tools.items.len > 0) {
        const last = &turn.streamed_tools.items[turn.streamed_tools.items.len - 1];
        if (last.phase == .streaming) {
            last.phase = .queued;
            try last.refresh(self.gpa);
        }
    }
    var streamed: StreamedTool = .{
        .name = try self.gpa.dupe(u8, name),
        .bytes = 0,
        // A reply that already committed cannot be streaming a new call, so a
        // row that opens here always counts.
        .phase = .streaming,
        .box = .empty,
    };
    errdefer streamed.deinit(self.gpa);
    try streamed.refresh(self.gpa);
    try turn.streamed_tools.append(self.gpa, streamed);
}

/// Count one streamed argument fragment against the call that opened last. A
/// fragment that arrives before any name has no row to count against, so it
/// shows nothing.
fn growStreamedTool(self: *Session, turn: *Turn, delta: []const u8) !void {
    if (turn.streamed_tools.items.len == 0) return;
    const streamed = &turn.streamed_tools.items[turn.streamed_tools.items.len - 1];
    // A stream can open a call without naming it, which opens no row of its own.
    // The last row is then a waiting one left by an earlier call, and that call
    // already streamed its arguments. Only the row this reply opened last counts,
    // so a waiting row at the end means this fragment has no row at all.
    if (streamed.phase != .streaming) return;
    streamed.bytes += delta.len;
    try streamed.refresh(self.gpa);
}

/// Drop the streamed row that the call named `name` replaces: the oldest row of
/// that name, because both sides keep the order of the reply.
///
/// A call can reach here with no row of its own, because a stream can open a
/// call without naming it. Dropping nothing then is what keeps a sibling's row
/// in place: a positional drop takes the wrong one and the rows desynchronize
/// for the rest of the reply.
///
/// The reverse leaves a row behind: a reply that opens a call and commits a
/// different one keeps the first row until the turn ends. That row counts bytes
/// for a call that never starts, which costs one stale line and no wrong text.
///
/// Every row that stays goes stale. The first committed call proves the reply
/// closed, and a mutating call waits for the calls before it, so a row that
/// still counted wire bytes reports progress that stopped.
fn dropStreamedTool(self: *Session, turn: *Turn, name: []const u8) !void {
    for (turn.streamed_tools.items, 0..) |streamed, index| {
        if (!std.mem.eql(u8, streamed.name, name)) continue;
        var found = turn.streamed_tools.orderedRemove(index);
        found.deinit(self.gpa);
        break;
    }
    for (turn.streamed_tools.items) |*streamed| {
        if (streamed.phase == .stale) continue;
        // The text of a queued row does not change here. It is rewritten anyway,
        // because one path that always refreshes is cheaper to trust than a
        // second condition on the phase it came from.
        streamed.phase = .stale;
        try streamed.refresh(self.gpa);
    }
}

/// Drop every stale row when the next reply starts to stream.
///
/// A row goes stale only after a call of its own reply committed, and that reply
/// streams nothing more. Fresh streamed content therefore belongs to the next
/// reply, and a stale row under it names a call that never started. Without this
/// it sits above every later round of the turn.
///
/// A queued row of the reply that still streams stays. Its call waits for a name
/// its own reply has not committed yet.
fn dropStaleTools(self: *Session, turn: *Turn) void {
    var index: usize = 0;
    while (index < turn.streamed_tools.items.len) {
        if (turn.streamed_tools.items[index].phase != .stale) {
            index += 1;
            continue;
        }
        var stale = turn.streamed_tools.orderedRemove(index);
        stale.deinit(self.gpa);
    }
}

/// Drop every streamed row. A retry re-streams the reply, so the rows of the
/// attempt it discards go with its text.
fn clearStreamedTools(self: *Session, turn: *Turn) void {
    for (turn.streamed_tools.items) |*streamed| streamed.deinit(self.gpa);
    turn.streamed_tools.clearRetainingCapacity();
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

fn freeTurn(self: *Session, turn: *Turn) void {
    for (turn.tools.items) |*tool| tool.deinit(self.gpa);
    turn.tools.deinit(self.gpa);
    self.clearStreamedTools(turn);
    turn.streamed_tools.deinit(self.gpa);
    turn.box_view.deinit(self.gpa);
}

const test_model = ai.models.get(.anthropic, "claude-sonnet-4-6") orelse
    @compileError("test model is not in the model table");

fn applyEvent(session: *Session, generation: u64, payload: TurnEvent.Payload) !void {
    _ = try session.applyTurnEvent(&.{ .generation = generation, .payload = payload });
}

// One committed round: a reply, then a call that reports its real result. The
// sequence numbers mirror what the app's turn handler produces.
fn applyFinishedToolRound(session: *Session) !void {
    const gpa = session.gpa;
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "answer") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_result = .{
            .name = try gpa.dupe(u8, "bash"),
            .summary = .{ .text = try gpa.dupe(u8, "Time: 0.0s · Exit code: 0") },
            .is_error = false,
        } },
    });
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
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 80,
        .base = 0,
        .skip = 0,
    };
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
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 120,
        .base = 0,
        .skip = 0,
    };
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
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 80,
        .base = 0,
        .skip = 0,
    };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[Paste #1: 11 lines]") != null);

    // It expands back to the exact bytes for a send boundary.
    const expanded = try editor.expanded(.whole_prompt);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

// The app cancels a send-as-a-message offer on every key that is not an Enter, but
// a turn end is no key event. An abnormal end also returns uncommitted drafts to
// the editor, so an offer that survives names a line that left the screen.
// Every turn end runs through `endTurn`, so the drop belongs there. The footer goes
// with it: a notice that a key raised during the turn describes that turn, so it is
// no longer true at the prompt.
test "a turn end drops the send-as-a-message confirmation and the footer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    try session.applyOutcome(try ai.command.Outcome.reportNotice(
        gpa,
        .warning,
        "Enter: Queue as a message · Drinky does not recognize the command /nope.",
        .{},
    ));
    session.armConfirmation(.message);
    try session.abortTurn();

    try std.testing.expect(session.mode == .prompt);
    try std.testing.expect(!session.takeConfirmation(.message));
    try std.testing.expect(session.notice == null);

    // The restriction row takes the same path. It armed no offer, and it names the
    // turn that just ended, so it must not stay on the footer either.
    session.beginTurn(2);
    try session.applyOutcome(try ai.command.Outcome.reportNotice(
        gpa,
        .warning,
        "The command /model cannot run while a turn runs.",
        .{},
    ));
    try session.abortTurn();
    try std.testing.expect(session.notice == null);
}

// The first Esc of a new turn must warn, never cancel. A turn that ends with
// leftover steering auto-starts the next turn with no key between them, so only
// the turn boundaries can drop a confirmation that the ended turn armed.
test "a turn boundary drops the turn-cancel confirmation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    session.armConfirmation(.turn_cancel);
    session.endTurn();
    session.beginTurn(2);
    try std.testing.expect(!session.takeConfirmation(.turn_cancel));
    session.endTurn();
}

// A later row replaces the row that named an offer, so the offer cannot outlive it.
// Otherwise Enter sends a line that no row on the screen offers.
test "a new notice drops the send-as-a-message confirmation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.armConfirmation(.message);
    try session.applyOutcome(try ai.command.Outcome.reportNotice(
        gpa,
        .failure,
        "Drinky could not read the file.",
        .{},
    ));

    try std.testing.expect(!session.takeConfirmation(.message));
    try std.testing.expectEqualStrings(
        "Drinky could not read the file.",
        session.notice.?.content,
    );
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

test "a confirmation is one-shot and separate from its notice" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .warning, "A warning.", .{}),
    );
    session.armConfirmation(.message);
    session.clearNotice();
    try std.testing.expect(session.takeConfirmation(.message));
    try std.testing.expect(!session.takeConfirmation(.message));

    session.armConfirmation(.message);
    session.cancelConfirmation(.message);
    try std.testing.expect(!session.takeConfirmation(.message));
}

test "an event survives notice clearing until the conversation resets" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "Drinky changed the model.", .{}),
    );
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Temporary notice.", .{}),
    );
    session.clearNotice();

    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "Drinky changed the model.",
        session.transcript.blocks()[0].event.text.items,
    );
    session.dirty = false;
    session.resetConversation();
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(session.notice == null);
    // The post-condition the app depends on: a dirty model and a pending screen
    // reset. The next paint then runs, and it clears the screen.
    try std.testing.expect(session.dirty);
    try std.testing.expect(session.view.force_reset);
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
    try applyEvent(&session, 1, .{ .thinking = try gpa.dupe(u8, "reasoning") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "he") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "llo") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, "Lines: 2") },
        .is_error = false,
    } });
    // The result replaces its running box at once, not at turn end.
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.tools.items.len);
    try applyEvent(&session, 1, .{ .usage = .{
        .cost = 1.5,
        .saved = 0.25,
        .cache_usage = .{ .input = 10, .output = 20 },
    } });

    // The applied events mark the model dirty but paint nothing.
    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(f64, 1.5), session.stats_shown.cost);

    // A clean end leaves turn mode.
    try finishTurn(&session, 0);
    try std.testing.expect(!session.animating());

    // One paint renders the coalesced frame: reasoning, answer text, and the tool result.
    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "reasoning") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 2") != null);
}

test "a tool result box shows the line the tool decided" {
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
        .summary = .{ .text = try gpa.dupe(u8, "Lines: 3") },
        .is_error = false,
    } });
    try finishTurn(&session, 0);
    try session.paint(.{ .columns = 80, .rows = 24 });

    const painted = out.written();
    try std.testing.expectEqualStrings(
        "Tool: read · File: x\nLines: 3",
        session.transcript.blocks()[0].tool_result.text.items,
    );
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 3") != null);
}

// The tool decides the box line. A tool that decides none keeps the call row
// alone, and the block stays in the history. The box is then one row between its
// two padding rows.
test "a tool result without a box line keeps the call row alone" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "describe_config"),
        .input_json = try gpa.dupe(u8, "{}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "describe_config"),
        .is_error = false,
    } });
    try finishTurn(&session, 0);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Tool: describe_config",
        blocks[0].tool_result.text.items,
    );
    try std.testing.expectEqual(@as(usize, 3), blocks[0].rows(80));

    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: describe_config") != null);
}

// A failure states one sentence, and that sentence is the box line. The block
// takes the `Error` key, which names the severity after a copy loses the color.
test "a failed tool result keeps its sentence below the call row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const sentence = "Drinky could not read a.zig because of error FileNotFound.";
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a.zig\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, sentence), .kind = .sentence },
        .is_error = true,
    } });
    try finishTurn(&session, 0);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: read · File: a.zig\nError: " ++ sentence,
        blocks[0].tool_result.text.items,
    );
    // The instruction of a sentence sits at its end, so the box wraps it.
    try std.testing.expectEqual(ui.paint.Fit.wrap, blocks[0].tool_result.fit);
}

// A failed call that states measures names its own end, so the box adds no
// prefix and cuts the line the way a successful one does. The failure still
// reaches the color of the box.
test "a failed tool result that states measures takes no prefix" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"ls missing\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "bash"),
        .summary = .{
            .text = try gpa.dupe(u8, "Time: 0.4s · Exit code: 1 · Lines: 1"),
            .kind = .measures,
        },
        .is_error = true,
    } });
    try finishTurn(&session, 0);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: bash · Command: ls missing\nTime: 0.4s · Exit code: 1 · Lines: 1",
        blocks[0].tool_result.text.items,
    );
    try std.testing.expectEqual(ui.paint.Fit.head, blocks[0].tool_result.fit);
}

// While the model streams a call, the row counts the argument bytes instead of
// showing them. The count climbs like a download, so a long call reports its
// progress, and the row never slides. The committed call then names its subject.
test "a streamed tool call counts its bytes until the call commits" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"src/") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "App.zig\",\"content\"") });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(@as(usize, 31), session.mode.turn.streamed_tools.items[0].bytes);

    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };
    try session.paint(size);
    const streaming = out.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        streaming,
        "Tool: write · Received: 31 B · Status: Streaming",
    ) != null);
    // `Received` names the wire, and it is the only count in a box that reads
    // in bytes. No finished call reports a size, so no reader can take the
    // streamed count for the size of what the call wrote.
    try std.testing.expect(std.mem.indexOf(u8, streaming, "Size:") == null);
    // No JSON reaches the row, and nothing is cut, so nothing slides.
    try std.testing.expect(std.mem.indexOf(u8, streaming, "path") == null);
    try std.testing.expect(std.mem.indexOf(u8, streaming, "\u{2026}") == null);

    out.clearRetainingCapacity();
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "write"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"src/App.zig\",\"content\":\"x\"}"),
    } });
    // The committed call replaces the streamed row, one for one.
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.tools.items.len);
    session.view.resetScreen();
    try session.paint(size);
    const committed = out.written();
    // The row names the file, not the argument list around it.
    try std.testing.expect(std.mem.indexOf(u8, committed, "Tool: write · File: src/App.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, committed, "content") == null);
}

// A reply can ask for two calls. The first to commit must take its own streamed
// row and leave its sibling's, or the sibling disappears for as long as a
// mutating call runs.
test "a committed call replaces its own streamed row and leaves its sibling" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"a\"}") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"b\"}") });
    try std.testing.expectEqual(@as(usize, 2), session.mode.turn.streamed_tools.items.len);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "write"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    // One row went, and the row that stays belongs to the call still waiting.
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqualStrings("read", session.mode.turn.streamed_tools.items[0].name);

    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: write · File: a") != null);
    // The reply committed, so the sibling waits its turn. Its count stopped
    // climbing, and the row keeps that count next to the state it reached.
    try std.testing.expect(std.mem.indexOf(
        u8,
        painted,
        "Tool: read · Received: 12 B · Status: Queued",
    ) != null);
}

// A reply streams its calls one after the other, so the row above stops counting
// the moment the next call opens. It must then name the state it reached: a
// frozen count with no state reads as a call that hangs.
test "a streamed row that stopped counting reads as queued" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"a\"}") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"bb\"}") });

    // The first row keeps the count it reached, and only the newest row counts.
    const rows = session.mode.turn.streamed_tools.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings(
        "Tool: write · Received: 12 B · Status: Queued",
        rows[0].box.items,
    );
    try std.testing.expectEqualStrings(
        "Tool: read · Received: 13 B · Status: Streaming",
        rows[1].box.items,
    );

    // The reply that holds both calls still streams, so text of that reply must
    // keep the queued row. Only a committed reply leaves a row that goes.
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "and") });
    try std.testing.expectEqual(@as(usize, 2), session.mode.turn.streamed_tools.items.len);
}

// A narrow window cuts the tail of the row, so the order of the fields decides
// what a cut row keeps. The count must stay, because it is the field that
// reports progress. The phase is the field that goes, and the motion of the
// count still separates a call that receives from a call that waits.
test "a narrow window cuts the phase of a streamed row and keeps the count" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"a\"}") });

    try session.paint(.{ .columns = 40, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: write · Received: 12 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Streaming") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\u{2026}") != null);
}

// A long call must not grow the work of a frame. The row holds a count, so its
// cost does not follow the size of the arguments.
test "a streamed row stays one short line however long the arguments run" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    const chunk = "ä" ** 1024;
    for (0..8) |_|
        try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, chunk) });

    const streamed = &session.mode.turn.streamed_tools.items[0];
    try std.testing.expectEqual(@as(usize, 8 * 2048), streamed.bytes);
    try std.testing.expectEqualStrings(
        "Tool: write · Received: 16.0 KB · Status: Streaming",
        streamed.box.items,
    );
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, streamed.box.items, "\n"));
}

// A retry re-streams the reply, so the boxes of the discarded attempt go with
// its text.
test "a stream reset drops the tool boxes of the discarded attempt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "partial") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\"") });
    try applyEvent(&session, 1, .stream_reset);
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);

    // A fragment that arrives with no open call shows nothing and appends
    // nothing.
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "orphan") });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
    try session.paint(.{ .columns = 40, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "orphan") == null);
}

// A provider can switch a request to another model. The event names both
// models in a durable block, so the switch survives in the history and the
// streamed answer around it stays intact.
test "a model mismatch records a durable event beside the answer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "answer") });
    try applyEvent(&session, 1, .{ .model_mismatch = .{
        .requested = try gpa.dupe(u8, "claude-fable-5"),
        .served = try gpa.dupe(u8, "claude-opus-5"),
    } });

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("answer", blocks[0].model.items);
    try std.testing.expect(blocks[1].event.is_error);
    try std.testing.expectEqualStrings(
        "The provider answered with the model \"claude-opus-5\" instead of the " ++
            "requested model \"claude-fable-5\".",
        blocks[1].event.text.items,
    );
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
    // The tool decides the box line, so the hostile bytes ride on that line.
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, tool) },
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

// A worker event can arrive after the turn ends (a straggler from a canceled
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
test "a canceled turn's stale output and completion cannot affect its successor" {
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

// A picked line that takes an argument lands in the editor, so the user adds the
// task and sends it. It replaces whatever the editor holds.
test "a picked line replaces the draft in the editor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    try session.editor.insert("stale text");
    try session.applyOutcome(.{ .editor_text = try gpa.dupe(u8, "/skill:demo ") });
    try std.testing.expectEqualStrings("/skill:demo ", session.editor.visible());
    try std.testing.expect(session.mode == .prompt);

    try session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "/skill:demo") != null);
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

// The activity clock advances between stream events. Each horizontal step
// repaints the two separator segments.
test "activity ticks repaint each separator step" {
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
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 40), session.mode.turn.activity_tick);
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

// Drinky blinks the caret itself during a turn, because the terminal holds its own
// cursor solid while Drinky writes a frame every 16 ms.
test "an edit restarts the caret blink of a running turn" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    _ = session.advanceFrame();
    _ = session.advanceFrame();
    try std.testing.expectEqual(@as(u64, 2), session.mode.turn.caret_tick);

    session.dirty = false;
    session.markEdited();
    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(u64, 0), session.mode.turn.caret_tick);

    // An idle input carries no blink clock, because the terminal blinks it.
    session.deinitMode();
    session.mode = .prompt;
    session.dirty = false;
    session.markEdited();
    try std.testing.expect(session.dirty);
}

test "a running turn hides and shows the hardware cursor of the input" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    try session.editor.insert("hi");

    var hidden = false;
    var shown_again = false;
    // About two blink cycles at 16 ms per frame.
    for (0..160) |_| {
        const start = out.written().len;
        _ = session.advanceFrame();
        try session.paint(.{ .columns = 40, .rows = 24 });
        const frame = out.written()[start..];
        if (!hidden) {
            hidden = std.mem.indexOf(u8, frame, terminal.escape.cursor_hide) != null;
        } else if (!shown_again) {
            shown_again = std.mem.indexOf(u8, frame, terminal.escape.cursor_show) != null;
        }
    }
    try std.testing.expect(hidden);
    try std.testing.expect(shown_again);
}

test "accepted turn progress restarts separator growth without resetting motion" {
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

    try session.transcript.append(.event, .{}, "earlier");
    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "my prompt");
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
    try session.transcript.append(.user, .{}, "prompt");
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
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].user.items);
    try std.testing.expectEqualStrings("round one", blocks[1].model.items);
    // The committed round holds the call, so the unfinished tool shows as failed.
    try std.testing.expect(blocks[2].tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: read\nError: " ++ ai.Agent.unfinished_tool_result,
        blocks[2].tool_result.text.items,
    );
    try std.testing.expect(blocks[3].event.is_error);
    try std.testing.expectEqualStrings("boom", blocks[3].event.text.items);
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
    try session.transcript.append(.event, .{}, "earlier");
    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "my prompt");
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
    try session.transcript.append(.user, .{}, "prompt");
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

// The agent commits the reply and one error result per call before it
// dispatches a tool. A cancel during the call must show that call as failed,
// because the next request carries it.
test "a cancel during a tool call keeps the call and shows it as failed" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .thinking = try gpa.dupe(u8, "I run one command.") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{\"command\":\"sleep 600\"}"),
        } },
    });

    try session.reserveSteeringRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 3,
        .steering_committed_count = 0,
    }, 1);
    try session.abortTurn();

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].user.items);
    try std.testing.expectEqualStrings("I run one command.", blocks[1].thinking.items);
    try std.testing.expect(blocks[2].tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: bash · Command: sleep 600\nError: " ++ ai.Agent.unfinished_tool_result,
        blocks[2].tool_result.text.items,
    );
    try std.testing.expect(!blocks[3].event.is_error);
    try std.testing.expectEqualStrings("You canceled the turn.", blocks[3].event.text.items);
    try std.testing.expect(session.mode == .prompt);
}

// Read-only calls of one reply run in parallel, so a cancel can find several
// running. Their blocks must keep call order.
test "running tool calls fail oldest first" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    // Each call names a distinct subject, so the rows below stay tellable apart.
    // The two tools label their subject differently, which the rows must keep.
    const names = [_][]const u8{ "read", "grep", "read" };
    const subjects = [_][]const u8{ "path", "pattern", "path" };
    const labels = [_][]const u8{ "File", "Pattern", "File" };
    for (names, subjects, 0..) |name, key, index| {
        _ = try session.applyTurnEvent(&.{
            .generation = 1,
            .progress_sequence = index + 1,
            .payload = .{ .tool_start = .{
                .name = try gpa.dupe(u8, name),
                .input_json = try std.fmt.allocPrint(
                    gpa,
                    "{{\"{s}\":\"item{d}\"}}",
                    .{ key, index },
                ),
            } },
        });
    }
    try session.abortTurn();

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(names.len + 1, blocks.len);
    for (names, labels, 0..) |name, label, index| {
        const head = try std.fmt.allocPrint(gpa, "Tool: {s} · {s}: item{d}\n", .{
            name,
            label,
            index,
        });
        defer gpa.free(head);
        try std.testing.expect(std.mem.startsWith(u8, blocks[index].tool_result.text.items, head));
    }
}

// A tool block of the ending round is committed history, so both abnormal
// terminals must keep it. The cancel adopts the worker's final frontier, which
// no event carried, because a canceled worker queues no terminal fence.
test "a finished tool block survives a cancel in the same round" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    try applyFinishedToolRound(&session);

    try session.reserveSteeringRestore();
    // `onToolResult` moved the worker's frontier to the result event.
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 3,
        .steering_committed_count = 0,
    }, 3);
    try session.abortTurn();

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expect(!blocks[2].tool_result.is_error);
    try std.testing.expect(
        std.mem.endsWith(u8, blocks[2].tool_result.text.items, "\nTime: 0.0s · Exit code: 0"),
    );
    try std.testing.expectEqualStrings("You canceled the turn.", blocks[3].event.text.items);
}

// The failure path takes that frontier from the worker's terminal fence instead.
test "a finished tool block survives a failure in the same round" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    try applyFinishedToolRound(&session);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 4,
        .progress_sequence_committed = 3,
        .payload = .turn_ended,
    });

    const receipt: ai.Agent.Receipt = .{
        .history_base = 0,
        .history_end = 3,
        .steering_committed_count = 0,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "boom");

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expect(!blocks[2].tool_result.is_error);
    try std.testing.expect(
        std.mem.endsWith(u8, blocks[2].tool_result.text.items, "\nTime: 0.0s · Exit code: 0"),
    );
    try std.testing.expectEqualStrings("boom", blocks[3].event.text.items);
}

test "a final commit frontier keeps an open reply when no later event carries it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
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
    try session.transcript.append(.user, .{}, "prompt");
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

// A skill that Drinky sent is no message of the user, so it must not read like
// one. It takes a head line of its own, and the file it names stays out.
test "a delivered skill shows as a head line, not as a user box" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.display_roots = .{ .working_directory = "/work", .home_directory = "/home/you" };
    session.beginTurn(1);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .skill_loaded = .{
            .skill = try gpa.dupe(u8, "zig-style"),
            .source = try gpa.dupe(u8, "/work/.agents/skills/zig-style/SKILL.md"),
        } },
    });

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .skill => |head| try std.testing.expectEqualStrings(
            "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md",
            head.items,
        ),
        else => return error.ExpectedSkill,
    }
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

// A command can run long enough that the user weighs a cancel. Its row reports
// how long it has run against how long it can run, so that choice rests on what
// the interface shows rather than on a guess.
test "a running command reports its run time against its timeout" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.bash_timeout_ms = 120_000;
    session.beginTurn(1);

    session.clock_ms = 1_000;
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"zig build test\"}"),
    } });

    session.clock_ms = 13_400;
    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: bash · Command: zig build test") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Time: 12.4s · Timeout: 2m 0s") != null,
    );
}

// A call that names its own timeout reports that one, not the configured
// default, or the row tells the user to expect the wrong wait.
test "a command that names its own timeout reports it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.bash_timeout_ms = 120_000;
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"sleep 5\",\"timeout_seconds\":5}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 5.0s") != null);
}

// Every other tool finishes promptly, so its box stays one row and reports no
// timeout it does not run under.
test "a tool without a timeout keeps one row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"src/App.zig\"}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: read · File: src/App.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Timeout:") == null);
}

// A timeout the model states in absurd numbers must not reach the display as a
// span that cannot be measured. The row paints instead of aborting the frame.
test "an absurd timeout still paints its row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(
            u8,
            "{\"command\":\"x\",\"timeout_seconds\":9223372036854775807}",
        ),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    // The clamp holds it at one hour, which is the wait the command really runs
    // under.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 60m 0s") != null);
}

// Regression: the configured timeout comes from a file the user writes, so it
// reaches the display without passing the argument parse. An unclamped one used
// to abort the frame on the cast into a signed span.
test "an absurd configured timeout still paints its row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.bash_timeout_ms = std.math.maxInt(u64);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"x\"}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 60m 0s") != null);
}

// No call runs without a limit, so a call that asks for none still names the
// smallest legal window. The row must never promise an open wait.
test "a command that asks for no limit reports the smallest one" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    session.clock_ms = 0;
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"tail -f log\",\"timeout_seconds\":0}"),
    } });
    // The clock stays inside the window, because the race kills the command at
    // the timeout, so a row never shows a run time past its limit.
    session.clock_ms = 500;
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(
        std.mem.indexOf(u8, out.written(), "Time: 0.5s · Timeout: 1.0s") != null,
    );
}

// A stream can open a call without naming it, so a fragment can arrive with no
// row of its own. It must not land on a stale row left by the reply before it:
// that row counts a call that already streamed, and the bytes vanish into it.
test "an unnamed fragment does not count against a stale row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "phantom") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    const stale = &session.mode.turn.streamed_tools.items[0];
    try std.testing.expectEqual(StreamedTool.Phase.stale, stale.phase);

    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"b\"}") });
    try std.testing.expectEqual(@as(usize, 0), stale.bytes);
    try std.testing.expectEqualStrings(
        "Tool: phantom · Received: 0 B · Status: Queued",
        stale.box.items,
    );
}

// A reply that opens one call and commits another leaves a row for a call that
// never starts. That row must not outlive its reply, or the next round shows a
// waiting call that nothing runs.
test "a stale row that its reply never committed goes with that reply" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "phantom") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    // The reply committed, so the row that no call claimed went stale.
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(
        StreamedTool.Phase.stale,
        session.mode.turn.streamed_tools.items[0].phase,
    );

    // The next reply starts to stream, which the committed one cannot do.
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "next") });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
}

// A stream can open a call without naming it, so a committed call can arrive
// with no streamed row of its own. Dropping a row by position then takes a
// sibling's row and desynchronizes the rest of the reply.
test "a committed call with no streamed row leaves its sibling's row alone" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();
    session.beginTurn(1);

    // Only the second call announced its name, so only it has a row.
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "grep") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"pattern\":\"x\"}") });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    // The unnamed call took no row, so the row that stays belongs to `grep`.
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqualStrings("grep", session.mode.turn.streamed_tools.items[0].name);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "grep"),
        .input_json = try gpa.dupe(u8, "{\"pattern\":\"x\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
}
