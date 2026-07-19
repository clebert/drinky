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
/// Steering messages queued while a turn runs, shown as the `Steering:` tail
/// rows. The display mirror of the agent's channel: `App` adds here and to the
/// channel together, and a `.steering_consumed` event drops the front as the
/// worker takes them. Each string owned.
steering: std.ArrayList([]u8),

const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
};

/// A streaming turn: the spinner frame and the tool calls currently running,
/// each shown as its own box in the live tail.
const Turn = struct {
    generation: u64,
    spinner_frame: usize,
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
    /// Command re-run with the chosen option when the picker is confirmed.
    command: []const u8,
};

/// A turn worker's message to the render consumer, tagged with the generation it
/// belongs to. Every payload owns its bytes until the consumer frees it.
pub const TurnEvent = struct {
    generation: u64,
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
        /// turn as one combined message: show it and drop those rows from the queue.
        steering_consumed: SteeringConsumed,
        turn_ended: ?[]u8,

        pub const Tool = struct { name: []u8, input_json: []u8 };
        pub const ToolResult = struct { name: []u8, content: []u8, is_error: bool };
        pub const SteeringConsumed = struct { text: []u8, count: usize };
    };

    pub fn deinit(self: TurnEvent, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .text, .thinking => |bytes| gpa.free(bytes),
            .tool_start => |tool| {
                gpa.free(tool.name);
                gpa.free(tool.input_json);
            },
            .tool_result => |result| {
                gpa.free(result.name);
                gpa.free(result.content);
            },
            .steering_consumed => |consumed| gpa.free(consumed.text),
            .turn_ended => |maybe_text| if (maybe_text) |text| gpa.free(text),
            .usage, .stream_reset => {},
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

    pub fn deinit(self: UiEvent, gpa: std.mem.Allocator) void {
        switch (self) {
            .keys => |bytes| gpa.free(bytes),
            .turn => |event| event.deinit(gpa),
            .tick, .resize => {},
        }
    }
};

/// Build an empty session at the default terminal size, painting through `writer`
/// and showing `model` and `effort` until a command changes them. Infallible: the
/// components own no resources until used.
pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, model: ai.models.Model, effort: ai.llm.Effort) Session {
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
    };
}

pub fn deinit(self: *Session) void {
    self.deinitMode();
    self.clearSteering();
    self.steering.deinit(self.gpa);
    self.transcript.deinit();
    self.view.deinit();
    self.editor.deinit();
}

/// Free whatever the current mode owns.
fn deinitMode(self: *Session) void {
    switch (self.mode) {
        .prompt => {},
        .turn => |*turn| self.freeTurn(turn),
        .picking => |*picking| picking.picker.deinit(),
    }
}

/// Apply one turn worker event to the model, marking it dirty and freeing the
/// event's bytes. Applying never paints. An event is dropped unless its captured
/// generation is still the active turn.
pub fn applyTurnEvent(self: *Session, event: TurnEvent) !void {
    defer event.deinit(self.gpa);
    const turn = self.activeTurn() orelse return;
    if (event.generation != turn.generation) return;
    self.dirty = true;
    switch (event.payload) {
        .text => |delta| try self.transcript.appendModelText(delta),
        .thinking => |delta| try self.transcript.appendThinkingText(delta),
        .tool_start => |tool| {
            self.transcript.endMessage();
            try pushTool(turn, self.gpa, tool.name, tool.input_json);
        },
        .tool_result => |result| try self.applyToolResult(result),
        .usage => |stats| self.stats_shown = stats,
        .stream_reset => self.transcript.discardMessage(),
        .steering_consumed => |consumed| {
            try self.transcript.append(.user, false, consumed.text);
            var removed: usize = 0;
            while (removed < consumed.count and self.steering.items.len > 0) : (removed += 1) {
                self.gpa.free(self.steering.orderedRemove(0));
            }
        },
        .turn_ended => |maybe_text| {
            if (maybe_text) |text| try self.transcript.append(.feedback, true, text);
            self.transcript.endMessage();
            self.endTurn();
        },
    }
}

/// Record a finished tool call in the transcript: its first output line beside the
/// box it closes, then free that box.
fn applyToolResult(self: *Session, result: TurnEvent.Payload.ToolResult) !void {
    const first = result.content[0 .. std.mem.indexOfScalar(u8, result.content, '\n') orelse result.content.len];
    const finished = if (self.activeTurn()) |turn| takeTool(turn, result.name) else null;
    defer if (finished) |*tool| self.freeTool(tool);
    const arguments = if (finished) |tool| tool.input_json else "";
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}\n→ {s}", .{ result.name, arguments, first });
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
        // The app intercepts account actions (they need the tty and the agent);
        // they never reach the io-free session.
        .login, .logout, .switch_account => unreachable,
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
    self.mode = .{ .picking = .{ .picker = picker, .command = pick.command } };
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

/// Mark the model changed since the last paint. The event-appliers and lifecycle
/// methods self-mark; call this after `App` mutates a widget (the editor, the
/// picker) directly.
pub fn markDirty(self: *Session) void {
    self.dirty = true;
}

/// Queue a steering message for display while a turn runs. `App` pushes the same
/// text onto the agent's channel so the worker can take it.
pub fn queueSteering(self: *Session, text: []const u8) !void {
    const copy = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(copy);
    try self.steering.append(self.gpa, copy);
    self.dirty = true;
}

/// Whether the steering queue is empty.
pub fn steeringEmpty(self: *const Session) bool {
    return self.steering.items.len == 0;
}

/// Drop every queued steering message.
pub fn clearSteering(self: *Session) void {
    for (self.steering.items) |message| self.gpa.free(message);
    self.steering.clearRetainingCapacity();
    self.dirty = true;
}

/// Close any open model run, then enter turn mode with a fresh spinner and no
/// active tools.
pub fn beginTurn(self: *Session, generation: u64) void {
    self.transcript.endMessage();
    self.mode = .{ .turn = .{
        .generation = generation,
        .spinner_frame = 0,
        .tools = .empty,
        .box_view = .empty,
    } };
    self.dirty = true;
}

/// Abort the running turn's model state: close the open run, drop the turn's
/// chrome, and record the cancellation. The io-side worker teardown is the
/// caller's.
pub fn abortTurn(self: *Session) !void {
    self.transcript.endMessage();
    self.endTurn();
    try self.transcript.append(.feedback, false, "cancelled");
    self.dirty = true;
}

/// Free the finished turn's tool state and return to waiting for input.
fn endTurn(self: *Session) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
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
    };

    const tail: layout.Tail = switch (self.mode) {
        .prompt => prompt: {
            self.editor.reflow(size.columns, size.rows);
            break :prompt .{ .prompt = &self.editor };
        },
        .turn => |*turn| turn: {
            self.editor.reflow(size.columns, size.rows);
            break :turn .{ .turn = .{
                .tools = try turn.boxes(self.gpa),
                .spinner = turn.spinner_frame,
                .steering = self.steering.items,
                .editor = &self.editor,
            } };
        },
        .picking => |*picking| picking: {
            picking.picker.reflow(size.columns, size.rows);
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

/// Advance one animation frame and report whether this tick repaints. A turn
/// steps the spinner every frame without marking the model dirty, so a tick
/// repaints on new model content or ongoing animation.
pub fn advanceFrame(self: *Session) bool {
    if (self.animating()) self.advanceSpinner();
    return self.dirty or self.animating();
}

/// Advance the spinner one frame. Driven by the frame timer while a turn runs, so
/// it animates independently of stream events.
fn advanceSpinner(self: *Session) void {
    switch (self.mode) {
        .turn => |*turn| turn.spinner_frame = ui.paint.spinnerStep(turn.spinner_frame),
        else => {},
    }
}

/// Whether a component wants continuous frames: today, a streaming turn's spinner.
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
fn pushTool(turn: *Turn, gpa: std.mem.Allocator, name: []const u8, input_json: []const u8) !void {
    const box = try std.fmt.allocPrint(gpa, "{s} {s}", .{ name, input_json });
    errdefer gpa.free(box);
    const name_copy = try gpa.dupe(u8, name);
    errdefer gpa.free(name_copy);
    const arguments = try gpa.dupe(u8, input_json);
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

fn turnEvent(generation: u64, payload: TurnEvent.Payload) TurnEvent {
    return .{ .generation = generation, .payload = payload };
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
    const placement: ui.paint.Placement = .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try editor.render(&placement, 24, true);
    try view.render();

    try std.testing.expectEqualStrings("hllo", editor.content());
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
        .paste => |text| try editor.insert(text),
        else => return error.UnexpectedInput,
    }
    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: ui.paint.Placement = .{ .sink = sink, .id = 0, .columns = 120, .base = 0, .skip = 0 };
    try editor.render(&placement, 24, true);
    try view.render();

    const painted = out.written();
    for ([_][]const u8{ "paste", "[9A", "]52;c;cGFzdGU=", "Pdata", "done", "\u{200B}�\u{200B}" }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, painted, text) != null);
    }
    for ([_][]const u8{ "\x1b[9A", "\x1b]52;c;cGFzdGU=\x07", "\x1bPdata\x1b\\" }) |control| {
        try std.testing.expect(std.mem.indexOf(u8, painted, control) == null);
    }
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
    try session.applyTurnEvent(turnEvent(1, .{ .text = try gpa.dupe(u8, "he") }));
    try session.applyTurnEvent(turnEvent(1, .{ .text = try gpa.dupe(u8, "llo") }));
    try session.applyTurnEvent(turnEvent(1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } }));
    try session.applyTurnEvent(turnEvent(1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .content = try gpa.dupe(u8, "first line\nsecond"),
        .is_error = false,
    } }));
    try session.applyTurnEvent(turnEvent(1, .{ .usage = .{
        .cost = 1.5,
        .saved = 0.25,
        .last = .{ .input = 10, .output = 20 },
    } }));

    // Applying marks the model dirty but paints nothing.
    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(f64, 1.5), session.stats_shown.cost);

    // A clean end leaves turn mode.
    try session.applyTurnEvent(turnEvent(1, .{ .turn_ended = null }));
    try std.testing.expect(!session.animating());

    // One paint renders the coalesced frame: streamed text and the tool result.
    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "first line") != null);
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
    try session.applyTurnEvent(turnEvent(1, .{ .text = try gpa.dupe(u8, streamed) }));
    try session.applyTurnEvent(turnEvent(1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{}"),
    } }));
    try session.applyTurnEvent(turnEvent(1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .content = try gpa.dupe(u8, tool),
        .is_error = false,
    } }));
    try session.applyTurnEvent(turnEvent(1, .{ .turn_ended = null }));
    try session.paint(.{ .columns = 160, .rows = 24 });

    const painted = out.written();
    for ([_][]const u8{
        "reply", "[8A", "]52;c;bW9kZWw=", "_payload", "tool", "]52;c;dG9vbA==", "Ppayload", "2Jdone",
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

    try session.applyTurnEvent(turnEvent(1, .{ .text = try gpa.dupe(u8, "straggler") }));
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(!session.dirty);
}

// Cancellation, resubmission, and these delayed events can all be entries in one
// batch that App already drained from the shared queue.
test "a cancelled turn's stale output and normal completion cannot affect its successor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    try session.applyTurnEvent(turnEvent(1, .{ .text = try gpa.dupe(u8, "turn A") }));
    try session.abortTurn();
    session.beginTurn(2);

    try session.applyTurnEvent(turnEvent(1, .{ .text = try gpa.dupe(u8, "stale A") }));
    try session.applyTurnEvent(turnEvent(1, .{ .turn_ended = null }));
    try std.testing.expect(session.animating());

    try session.applyTurnEvent(turnEvent(2, .{ .text = try gpa.dupe(u8, "turn B") }));
    try session.applyTurnEvent(turnEvent(2, .{ .turn_ended = null }));
    try std.testing.expect(!session.animating());
    try std.testing.expectEqual(@as(usize, 3), session.transcript.blocks().len);
    try std.testing.expectEqualStrings("turn B", session.transcript.blocks()[2].model.items);
}

test "a cancelled turn's stale error completion cannot affect its successor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    session.beginTurn(1);
    try session.abortTurn();
    session.beginTurn(2);

    try session.applyTurnEvent(turnEvent(1, .{
        .turn_ended = try gpa.dupe(u8, "turn A failed"),
    }));
    try std.testing.expect(session.animating());

    try session.applyTurnEvent(turnEvent(2, .{ .text = try gpa.dupe(u8, "turn B") }));
    try session.applyTurnEvent(turnEvent(2, .{ .turn_ended = null }));
    try std.testing.expect(!session.animating());
    try std.testing.expectEqual(@as(usize, 2), session.transcript.blocks().len);
    try std.testing.expectEqualStrings("turn B", session.transcript.blocks()[1].model.items);
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

    try session.queueSteering("fix it");
    try session.queueSteering("and test");
    try std.testing.expect(!session.steeringEmpty());
    try std.testing.expectEqual(@as(usize, 2), session.steering.items.len);
    try std.testing.expectEqualStrings("fix it", session.steering.items[0]);

    try session.applyTurnEvent(turnEvent(1, .{ .steering_consumed = .{
        .text = try gpa.dupe(u8, "fix it\n\nand test"),
        .count = 2,
    } }));
    try std.testing.expect(session.steeringEmpty());
    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
    try std.testing.expectEqualStrings("fix it\n\nand test", session.transcript.blocks()[0].user.items);
}

// Regression: while a turn animates, a tick must repaint even when the model is
// clean, or the spinner freezes between stream events. `advanceFrame` also steps
// the spinner, and reports no repaint when idle.
test "a tick repaints and steps the spinner while a turn animates" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .none);
    defer session.deinit();

    // Animating and clean still repaints, and the spinner advances one frame.
    session.beginTurn(1);
    session.dirty = false;
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.spinner_frame);
    session.deinitMode();

    // Idle — clean and not animating — repaints nothing.
    session.mode = .prompt;
    session.dirty = false;
    try std.testing.expect(!session.advanceFrame());

    // New model content repaints even without animation.
    session.dirty = true;
    try std.testing.expect(session.advanceFrame());
}
