//! The composition root and event loop. Wires the terminal, reconciling view,
//! input parser, editor, and agent together: ensures the user is authenticated,
//! then drives the interface off a single event channel — producer tasks push
//! `UiEvent`s onto it, one consumer applies them to the model and paints.
//!
//! Network and stream I/O run off the UI thread. Three `io.concurrent` producers
//! feed one `std.Io.Queue(UiEvent)`: a long-lived input reader (stdin → `.keys`),
//! the current turn worker (`agent.run` → `.text`/`.tool_*`/`.usage`/`.turn_ended`),
//! and a one-shot frame timer (sleep → `.tick`). The consumer — the sole owner of
//! the model and the only thing that paints — blocks on the channel, drains a
//! coalesced batch, applies each event (marking the model dirty, never painting),
//! and paints only when it drains a `.tick`. A tick is armed whenever the model is
//! dirty or a turn animates and none is pending, so a clean idle interface arms no
//! tick and stays inert.
//!
//! `Transcript` holds the blocks above the live tail and the "model run"
//! invariant; `layout` projects the visible scene onto the bounded window;
//! `refresh`/`paint` are the render seam, a pure function of the consumer-owned
//! model (stats and model snapshots included) with no live tty or agent needed.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const layout = @import("layout.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");

const App = @This();

const model = "claude-sonnet-4-6";
const model_info = ai.models.get(.anthropic, model) orelse
    @compileError("default model \"" ++ model ++ "\" is not in the model table");
const system_prompt =
    "You are pith, a small coding assistant running in a terminal. Be concise. " ++
    "Explore the working directory with find (by name) and grep (literal text in file contents), read files " ++
    "with read, create or overwrite them with write, and change existing files with edit " ++
    "(give old_text that occurs exactly once).";

const intro_text = "pith — enter: send · shift+enter: newline · esc: cancel · ctrl+c: clear (twice: quit) · ctrl+d: quit";

/// Two Ctrl+C presses within this window quit; a lone press clears the editor.
const ctrl_c_window_ms = 500;

/// Target frame interval: paints are rate-limited to one per this window, so a
/// keystroke echoes within it and a burst of stream events coalesces into it.
const frame_interval_ms = 16;

/// Events the channel buffers before a producer blocks in `putOne`. One batched
/// `get` drains up to this many at once, so a whole burst collapses into a frame.
const queue_capacity = 256;

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
view: terminal.View,
input: terminal.Input,
editor: ui.Editor,
auth: ai.anthropic.Auth,
agent: ai.Agent,
transcript: Transcript,
columns: usize,
rows: usize,
running: bool,
last_ctrl_c: i64,
/// The current interaction: waiting for input, streaming a turn, or picking.
mode: Mode,
/// The one cross-thread channel: producer tasks push `UiEvent`s, the consumer
/// drains and applies them. Backed by `queue_buffer`, so pin the `App`.
queue: std.Io.Queue(UiEvent),
queue_buffer: [queue_capacity]UiEvent,
/// The long-lived stdin reader task; cancelled and reaped at shutdown.
input_future: std.Io.Future(void),
/// The running turn worker, or null between turns.
turn_future: ?std.Io.Future(void),
/// The pending frame timer, or null when none is armed (idle or clean).
tick_future: ?std.Io.Future(void),
/// The model changed since the last paint; the next tick repaints and clears it.
dirty: bool,
/// A frame timer is armed and its `.tick` has not been drained yet.
tick_pending: bool,
/// Monotonic time of the last paint, so the next tick lands one interval later.
last_paint_ms: i64,
/// Consumer-owned copy of the agent's usage/cost, updated by `.usage` events so
/// the status gauge never reads `agent.stats` across the worker thread.
stats_shown: ai.Agent.Stats,
/// Consumer-owned copy of the active model, updated by `/model`, so `paint` needs
/// no agent for the context-window and model-name gauges.
model_shown: ai.models.Model,

/// The current interaction. Exactly one input is live: the editor while waiting
/// (`prompt`) or streaming a turn (`turn`, where it is inert), or a `picker`.
const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
};

/// A streaming turn: the spinner frame and the tool calls currently running,
/// each shown as its own box in the live tail.
const Turn = struct {
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

/// A message from a producer task to the render consumer. Every payload owns its
/// bytes: the producer allocates them from the shared gpa, the consumer frees
/// them after applying. `.usage` is a plain value and `.tick` is empty; neither
/// owns anything.
const UiEvent = union(enum) {
    keys: []u8,
    text: []u8,
    tool_start: Tool,
    tool_result: ToolResult,
    usage: ai.Agent.Stats,
    turn_ended: ?[]u8,
    tick,

    const Tool = struct { name: []u8, input_json: []u8 };
    const ToolResult = struct { name: []u8, content: []u8, is_error: bool };

    fn deinit(self: UiEvent, gpa: std.mem.Allocator) void {
        switch (self) {
            .keys, .text => |bytes| gpa.free(bytes),
            .tool_start => |tool| {
                gpa.free(tool.name);
                gpa.free(tool.input_json);
            },
            .tool_result => |result| {
                gpa.free(result.name);
                gpa.free(result.content);
            },
            .turn_ended => |maybe_text| if (maybe_text) |text| gpa.free(text),
            .usage, .tick => {},
        }
    }
};

/// The turn worker's presentation handler: instead of mutating the transcript, it
/// enqueues owned `UiEvent`s for the consumer. Lives on the worker thread, so it
/// touches only the thread-safe channel and gpa. `agent.run`'s `anytype` handler
/// makes this a drop-in for the consumer-side handler.
const TurnHandler = struct {
    app: *App,
    /// Owned error text captured from `onError`, which the agent calls just before
    /// a failed turn returns; the worker carries it into the single `.turn_ended`.
    error_text: ?[]u8 = null,

    pub fn onText(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.app.queue.putOne(self.app.io, .{ .text = copy });
    }

    pub fn onToolStart(self: *TurnHandler, name: []const u8, input_json: []const u8) !void {
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const json_copy = try self.app.gpa.dupe(u8, input_json);
        errdefer self.app.gpa.free(json_copy);
        try self.app.queue.putOne(self.app.io, .{ .tool_start = .{ .name = name_copy, .input_json = json_copy } });
    }

    pub fn onToolResult(self: *TurnHandler, name: []const u8, content: []const u8, is_error: bool) !void {
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const content_copy = try self.app.gpa.dupe(u8, content);
        errdefer self.app.gpa.free(content_copy);
        try self.app.queue.putOne(self.app.io, .{ .tool_result = .{
            .name = name_copy,
            .content = content_copy,
            .is_error = is_error,
        } });
    }

    pub fn onUsage(self: *TurnHandler, stats: ai.Agent.Stats) !void {
        try self.app.queue.putOne(self.app.io, .{ .usage = stats });
    }

    pub fn onError(self: *TurnHandler, text: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, text);
        if (self.error_text) |old| self.app.gpa.free(old);
        self.error_text = copy;
    }
};

/// Authenticate (logging in if needed), then run the interactive loop until the
/// user quits or stdin closes. Pin the value: streams and the channel borrow its
/// buffers.
pub fn run(self: *App, gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    self.gpa = gpa;
    self.io = io;
    self.columns = 80;
    self.rows = 24;
    self.last_ctrl_c = 0;
    self.mode = .prompt;
    self.dirty = false;
    self.tick_pending = false;
    self.last_paint_ms = 0;
    self.turn_future = null;
    self.tick_future = null;
    self.stats_shown = .{};
    self.queue = std.Io.Queue(UiEvent).init(&self.queue_buffer);
    defer self.deinitMode();
    self.transcript = Transcript.init(gpa);
    defer self.transcript.deinit();

    self.auth = try ai.anthropic.Auth.init(gpa, io, home);
    defer self.auth.deinit();
    try self.ensureAuth();

    self.agent = ai.Agent.init(gpa, io, ai.provider.Client.init(.anthropic, gpa, io, &self.auth), .{ .model = model_info, .system = system_prompt });
    defer self.agent.deinit();
    self.model_shown = self.agent.model;

    try self.tty.init(io);
    defer self.tty.deinit();
    self.view = terminal.View.init(gpa, self.tty.writer());
    defer self.view.deinit();
    self.input = terminal.Input.init(gpa);
    defer self.input.deinit();
    self.editor = ui.Editor.init(gpa);
    defer self.editor.deinit();

    try self.transcript.append(.intro, false, intro_text);
    try self.refresh();
    self.last_paint_ms = self.nowMs();

    self.running = true;
    self.input_future = try self.io.concurrent(readInput, .{self});
    defer self.shutdownTasks();

    try self.runLoop();
}

/// Cancel and reap every producer task, then drain and free any events they left
/// buffered. Runs before `tty.deinit`, so the reader has stopped touching stdin
/// before termios is restored.
fn shutdownTasks(self: *App) void {
    if (self.turn_future) |*future| {
        future.cancel(self.io);
        self.turn_future = null;
    }
    self.input_future.cancel(self.io);
    if (self.tick_future) |*future| {
        future.cancel(self.io);
        self.tick_future = null;
    }
    self.drainQueue();
}

/// Free every event still buffered on the channel. Only safe once the producers
/// are reaped, so no new event can arrive mid-drain.
fn drainQueue(self: *App) void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (true) {
        const count = self.queue.get(self.io, &batch, 0) catch break;
        if (count == 0) break;
        for (batch[0..count]) |event| event.deinit(self.gpa);
    }
}

/// The consumer: block on the channel, drain a coalesced batch, apply each event
/// to the model, and paint only on a `.tick`. A tick is armed whenever the model
/// is dirty or a turn animates and none is pending, so a clean idle interface
/// stays inert (no tick, blocked on an empty channel).
fn runLoop(self: *App) !void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (self.running) {
        const count = self.queue.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed, error.Canceled => break,
        };
        var ticked = false;
        for (batch[0..count]) |event| switch (event) {
            .tick => ticked = true,
            .keys => |bytes| {
                defer self.gpa.free(bytes);
                try self.handleKeys(bytes);
            },
            else => try self.applyStreamEvent(event),
        };
        if (!self.animating()) {
            if (self.turn_future) |*future| {
                future.await(self.io);
                self.turn_future = null;
            }
        }
        if (ticked) {
            self.tick_pending = false;
            if (self.tick_future) |*future| {
                future.await(self.io);
                self.tick_future = null;
            }
            if (self.advanceFrame()) {
                try self.refresh();
                self.dirty = false;
                self.last_paint_ms = self.nowMs();
            }
        }
        if ((self.dirty or self.animating()) and !self.tick_pending) self.armTick();
    }
}

/// Arm the next frame: a one-shot timer that fires at `last_paint + interval`. On
/// the impossible failure to spawn it, paint inline so the frame is not lost.
fn armTick(self: *App) void {
    const elapsed = self.nowMs() - self.last_paint_ms;
    const delay_ms: i64 = if (elapsed >= frame_interval_ms) 0 else frame_interval_ms - elapsed;
    self.tick_future = self.io.concurrent(frameTimer, .{ self, delay_ms }) catch {
        self.refresh() catch {};
        self.dirty = false;
        self.last_paint_ms = self.nowMs();
        return;
    };
    self.tick_pending = true;
}

/// Frame timer task: sleep until the deadline, then push one `.tick`. Cancelled at
/// shutdown or when its frame is superseded; a cancel just drops the tick.
fn frameTimer(self: *App, delay_ms: i64) void {
    if (delay_ms > 0) self.io.sleep(.fromMilliseconds(delay_ms), .awake) catch return;
    self.queue.putOne(self.io, .tick) catch {};
}

/// Input reader task: block on stdin and push each chunk as owned `.keys`. Exits
/// on cancel (shutdown); on stdin close or a read fault it closes the channel so
/// the consumer's `get` returns `error.Closed` and the program winds down.
fn readInput(self: *App) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const result = self.tty.read(&buffer, .none) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                self.queue.close(self.io);
                return;
            },
        };
        const count = result orelse continue;
        if (count == 0) continue;
        const copy = self.gpa.dupe(u8, buffer[0..count]) catch {
            self.queue.close(self.io);
            return;
        };
        self.queue.putOne(self.io, .{ .keys = copy }) catch {
            self.gpa.free(copy);
            return;
        };
    }
}

/// Turn worker task: run one turn through a `TurnHandler`, then push the single
/// `.turn_ended` (carrying any error text). A cancelled turn pushes nothing — the
/// consumer that cancelled it owns the teardown. `agent.run`'s `errdefer` rolls
/// `messages` back to the turn base on every error path.
fn runTurnWorker(self: *App, text: []u8) void {
    defer self.gpa.free(text);
    var handler: TurnHandler = .{ .app = self };
    self.agent.run(text, &handler) catch |err| switch (err) {
        error.Canceled, error.Closed => {
            if (handler.error_text) |extra| self.gpa.free(extra);
            return;
        },
        else => {
            if (handler.error_text == null)
                handler.error_text = self.gpa.dupe(u8, @errorName(err)) catch null;
        },
    };
    self.queue.putOne(self.io, .{ .turn_ended = handler.error_text }) catch {
        if (handler.error_text) |extra| self.gpa.free(extra);
    };
}

fn ensureAuth(self: *App) !void {
    if (try self.auth.load()) return;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(self.io, &buffer);
    try self.auth.login(&stdout.interface);
}

/// Decode a stdin chunk into key events and apply each. Runs on the consumer, so
/// a submitted line spawns a turn worker and ctrl-c cancels a running one.
fn handleKeys(self: *App, bytes: []const u8) !void {
    try self.input.feed(bytes);
    while (self.input.next()) |event| try self.handleKey(event);
}

fn handleKey(self: *App, event: terminal.Input.Key) !void {
    switch (self.mode) {
        .picking => return self.handlePickerKey(event),
        .turn => return self.handleTurnKey(event),
        .prompt => {},
    }
    switch (event) {
        .char => |codepoint| try self.editor.insertCodepoint(codepoint),
        .paste => |text| try self.editor.insert(text),
        .backspace => self.editor.backspace(),
        .left => self.editor.moveLeft(),
        .right => self.editor.moveRight(),
        .up => self.editor.moveUp(self.columns),
        .down => self.editor.moveDown(self.columns),
        .home => self.editor.moveHome(),
        .end => self.editor.moveEnd(),
        .enter => return self.submit(),
        .newline => try self.editor.insert("\n"),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (!self.running) return;
            },
            'd' => {
                if (self.editor.content().len == 0) {
                    self.running = false;
                    return;
                }
            },
            'j' => try self.editor.insert("\n"),
            else => return,
        },
        .escape, .unknown => return,
    }
    self.dirty = true;
}

/// Keys during a streaming turn: ctrl-c or esc cancels it; everything else is
/// ignored (steering — typing while a turn runs — is a separate backlog item).
fn handleTurnKey(self: *App, event: terminal.Input.Key) !void {
    switch (event) {
        .escape => try self.cancelTurn(),
        .ctrl => |letter| switch (letter) {
            'c' => try self.cancelTurn(),
            else => {},
        },
        else => {},
    }
}

/// Abort the running turn: cancel and reap the worker (interrupting its blocked
/// network read), close the open model run, and drop the turn's chrome. Any
/// events the worker already queued are dropped when applied, since the mode is
/// no longer a turn.
fn cancelTurn(self: *App) !void {
    if (self.turn_future) |*future| {
        future.cancel(self.io);
        self.turn_future = null;
    }
    self.transcript.endModelRun();
    self.endTurn();
    try self.transcript.append(.feedback, false, "cancelled");
    self.dirty = true;
}

/// Ctrl+C: clear the editor, or quit when pressed twice inside the window.
fn clearOrQuit(self: *App) void {
    const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    if (now - self.last_ctrl_c < ctrl_c_window_ms) {
        self.running = false;
    } else {
        self.editor.clear();
        self.last_ctrl_c = now;
    }
}

/// Repaint: read the terminal size (keeping the last known one if the query
/// fails), then hand the model to the projection at that size. Reading size here
/// picks up a resize on the next frame while a turn animates.
fn refresh(self: *App) !void {
    const size: terminal.View.Size = if (self.tty.size()) |window|
        .{ .columns = window.columns, .rows = window.rows }
    else
        .{ .columns = self.columns, .rows = self.rows };
    self.columns = size.columns;
    self.rows = size.rows;
    try self.paint(size);
}

/// Assemble the visible scene from the consumer-owned model and project it. Pure
/// in the model, stats, and model snapshots — no tty or agent — so the consumer
/// can be driven from a scripted event sequence in tests.
fn paint(self: *App, size: terminal.View.Size) !void {
    const status: ui.status.Info = .{
        .last = self.stats_shown.last,
        .cost = self.stats_shown.cost,
        .saved = self.stats_shown.saved,
        .context_window = self.model_shown.context_window,
        .model = self.model_shown.name,
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

/// Advance the spinner one frame. Driven by the frame timer while a turn runs, so
/// it animates independently of stream events.
fn advanceSpinner(self: *App) void {
    switch (self.mode) {
        .turn => |*turn| turn.spinner_frame = ui.paint.spinnerStep(turn.spinner_frame),
        else => {},
    }
}

/// Whether a component wants continuous frames: today, a streaming turn's spinner.
fn animating(self: *const App) bool {
    return switch (self.mode) {
        .turn => true,
        else => false,
    };
}

/// Advance one animation frame and report whether this tick repaints. A turn
/// steps the spinner every frame without marking the model dirty, so a tick
/// repaints on new model content or ongoing animation.
fn advanceFrame(self: *App) bool {
    if (self.animating()) self.advanceSpinner();
    return self.dirty or self.animating();
}

/// The running turn, if a turn is streaming.
fn activeTurn(self: *App) ?*Turn {
    return switch (self.mode) {
        .turn => |*turn| turn,
        else => null,
    };
}

/// Milliseconds on the monotonic clock, for frame scheduling.
fn nowMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

fn submit(self: *App) !void {
    const trimmed = std.mem.trim(u8, self.editor.content(), " \t\r\n");
    if (trimmed.len == 0) return;
    const text = try self.gpa.dupe(u8, trimmed);
    defer self.gpa.free(text);
    self.editor.clear();
    self.dirty = true;

    if (std.mem.startsWith(u8, text, "/")) {
        try self.runCommand(text);
    } else {
        try self.transcript.append(.user, false, text);
        try self.runTurn(text);
    }
}

/// Spawn a turn worker over `text` and enter turn mode. The worker owns its own
/// copy of the prompt; only commit to turn mode once the spawn succeeds.
fn runTurn(self: *App, text: []const u8) !void {
    // A worker that finished earlier in this same batch (its `.turn_ended` already
    // flipped the mode back to prompt) is not reaped until after the batch, so
    // reap it here before its handle is overwritten.
    if (self.turn_future) |*future| {
        future.await(self.io);
        self.turn_future = null;
    }
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    self.transcript.endModelRun();
    self.turn_future = try self.io.concurrent(runTurnWorker, .{ self, owned });
    self.mode = .{ .turn = .{ .spinner_frame = 0, .tools = .empty, .box_view = .empty } };
    self.dirty = true;
}

/// Free the finished turn's tool state and return to waiting for input.
fn endTurn(self: *App) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
    self.mode = .prompt;
}

/// Apply one worker event to the model, marking it dirty and freeing the event's
/// bytes. Applying never paints. A worker event that arrives once the turn is over
/// (a straggler from a just-cancelled turn) is freed and dropped.
fn applyStreamEvent(self: *App, event: UiEvent) !void {
    defer event.deinit(self.gpa);
    if (!self.animating()) return;
    self.dirty = true;
    switch (event) {
        .text => |delta| try self.transcript.appendModelText(delta),
        .tool_start => |tool| {
            self.transcript.endModelRun();
            if (self.activeTurn()) |turn| try pushTool(turn, self.gpa, tool.name, tool.input_json);
        },
        .tool_result => |result| try self.applyToolResult(result),
        .usage => |stats| self.stats_shown = stats,
        .turn_ended => |maybe_text| {
            if (maybe_text) |text| try self.transcript.append(.feedback, true, text);
            self.transcript.endModelRun();
            self.endTurn();
        },
        .keys, .tick => unreachable,
    }
}

/// Record a finished tool call in the transcript: its first output line beside the
/// box it closes, then free that box.
fn applyToolResult(self: *App, result: UiEvent.ToolResult) !void {
    const first = result.content[0 .. std.mem.indexOfScalar(u8, result.content, '\n') orelse result.content.len];
    const finished = if (self.activeTurn()) |turn| takeTool(turn, result.name) else null;
    defer if (finished) |*tool| self.freeTool(tool);
    const arguments = if (finished) |tool| tool.input_json else "";
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}\n→ {s}", .{ result.name, arguments, first });
    defer self.gpa.free(text);
    try self.transcript.append(.tool_result, result.is_error, text);
}

/// Handle a slash command locally: either print its feedback or open a picker.
fn runCommand(self: *App, line: []const u8) !void {
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    try self.handleOutcome(try ai.command.run(&context, line));
    self.model_shown = self.agent.model;
    self.dirty = true;
}

/// Apply a command outcome to the transcript state; the caller marks dirty.
fn handleOutcome(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .feedback => |feedback| {
            defer self.gpa.free(feedback.content);
            try self.transcript.append(.feedback, feedback.is_error, feedback.content);
        },
        .pick => |pick| try self.openPicker(pick),
    }
}

/// Enter picker mode over a command's options; navigation and confirmation run
/// through `handlePickerKey`. Takes ownership of `pick.options`.
fn openPicker(self: *App, pick: ai.command.Outcome.Pick) !void {
    errdefer {
        for (pick.options) |option| self.gpa.free(option);
        self.gpa.free(pick.options);
    }
    self.mode = .{ .picking = .{
        .picker = try ui.Picker.init(self.gpa, pick.title, pick.options, pick.current),
        .command = pick.command,
    } };
}

fn handlePickerKey(self: *App, event: terminal.Input.Key) !void {
    const picker = &self.mode.picking.picker;
    switch (event) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.cancelPicker(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.cancelPicker(),
            else => return,
        },
        else => return,
    }
    self.dirty = true;
}

/// Re-apply the picker's command with the highlighted option as its argument.
fn confirmPicker(self: *App) !void {
    const picking = &self.mode.picking;
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    const outcome = try ai.command.apply(&context, picking.command, picking.picker.choice());
    self.closePicker();
    try self.handleOutcome(outcome);
    self.model_shown = self.agent.model;
    self.dirty = true;
}

fn cancelPicker(self: *App) !void {
    self.closePicker();
    try self.transcript.append(.feedback, false, "cancelled");
    self.dirty = true;
}

fn closePicker(self: *App) void {
    switch (self.mode) {
        .picking => |*picking| {
            picking.picker.deinit();
            self.mode = .prompt;
        },
        else => {},
    }
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

fn freeTool(self: *App, tool: *const ActiveTool) void {
    self.gpa.free(tool.name);
    self.gpa.free(tool.input_json);
    self.gpa.free(tool.box);
}

fn freeTurn(self: *App, turn: *Turn) void {
    for (turn.tools.items) |*tool| self.freeTool(tool);
    turn.tools.deinit(self.gpa);
    turn.box_view.deinit(self.gpa);
}

/// Free whatever the current mode owns; called on shutdown.
fn deinitMode(self: *App) void {
    switch (self.mode) {
        .prompt => {},
        .turn => |*turn| self.freeTurn(turn),
        .picking => |*picking| picking.picker.deinit(),
    }
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

// The consumer seam without real io: a scripted turn's worker events drive the
// transcript, usage, and turn teardown; applying marks dirty but never paints;
// one paint then renders the coalesced frame. The heavy fields (io, tty, agent,
// auth, channel, futures) are untouched by `applyStreamEvent` and `paint`.
test "scripted stream events drive the model and one coalesced paint" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.columns = 80;
    app.rows = 24;
    app.dirty = false;
    app.stats_shown = .{};
    app.model_shown = model_info;
    app.transcript = Transcript.init(gpa);
    defer app.transcript.deinit();
    app.editor = ui.Editor.init(gpa);
    defer app.editor.deinit();
    app.view = terminal.View.init(gpa, &out.writer);
    defer app.view.deinit();
    app.mode = .{ .turn = .{ .spinner_frame = 0, .tools = .empty, .box_view = .empty } };
    defer app.deinitMode();

    // Owned payloads, exactly as a producer task would allocate them.
    try app.applyStreamEvent(.{ .text = try gpa.dupe(u8, "he") });
    try app.applyStreamEvent(.{ .text = try gpa.dupe(u8, "llo") });
    try app.applyStreamEvent(.{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } });
    try app.applyStreamEvent(.{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .content = try gpa.dupe(u8, "first line\nsecond"),
        .is_error = false,
    } });
    try app.applyStreamEvent(.{ .usage = .{ .cost = 1.5, .saved = 0.25, .last = .{ .input = 10, .output = 20 } } });

    // Applying marks the model dirty but paints nothing.
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(f64, 1.5), app.stats_shown.cost);

    // A clean end leaves turn mode.
    try app.applyStreamEvent(.{ .turn_ended = null });
    try std.testing.expect(!app.animating());

    // One paint renders the coalesced frame: streamed text and the tool result.
    try app.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "first line") != null);
}

// A worker event arriving after the turn ends (a straggler from a cancelled turn)
// is freed and dropped, not appended.
test "stream events are dropped once the turn is over" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.gpa = gpa;
    app.dirty = false;
    app.stats_shown = .{};
    app.mode = .prompt;
    app.transcript = Transcript.init(gpa);
    defer app.transcript.deinit();

    try app.applyStreamEvent(.{ .text = try gpa.dupe(u8, "straggler") });
    try std.testing.expectEqual(@as(usize, 0), app.transcript.blocks().len);
    try std.testing.expect(!app.dirty);
}

// Regression: while a turn animates, a tick must repaint even when the model is
// clean, or the spinner freezes between stream events. `advanceFrame` also steps
// the spinner, and reports no repaint when idle.
test "a tick repaints and steps the spinner while a turn animates" {
    var app: App = undefined;
    app.gpa = std.testing.allocator;

    // Animating and clean still repaints, and the spinner advances one frame.
    app.dirty = false;
    app.mode = .{ .turn = .{ .spinner_frame = 0, .tools = .empty, .box_view = .empty } };
    try std.testing.expect(app.advanceFrame());
    try std.testing.expectEqual(@as(usize, 1), app.mode.turn.spinner_frame);
    app.deinitMode();

    // Idle — clean and not animating — repaints nothing.
    app.mode = .prompt;
    app.dirty = false;
    try std.testing.expect(!app.advanceFrame());

    // New model content repaints even without animation.
    app.dirty = true;
    try std.testing.expect(app.advanceFrame());
}
