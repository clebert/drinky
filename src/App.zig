//! The composition root and event loop. Authenticates, wires the tty, agent, and
//! `Session` together, then runs the interface off a single event channel:
//! producer tasks push `Session.UiEvent`s onto it and the consumer loop here
//! drains them, driving the `Session` model and painting through it.
//!
//! Network and stream I/O run off the UI thread. Four `io.concurrent` producers
//! feed one `std.Io.Queue(Session.UiEvent)`: a long-lived input reader
//! (stdin → `.keys`), the current turn worker (`agent.run` →
//! `.text`/`.tool_*`/`.usage`/`.turn_ended`), a one-shot frame timer
//! (sleep → `.tick`), and a SIGWINCH watcher (self-pipe → `.resize`). The
//! consumer blocks on the channel, drains a coalesced batch, applies each event
//! to the `Session` (marking it dirty, never painting), and paints only when it
//! drains a `.tick`. A tick is armed whenever the session is dirty or a turn
//! animates and none is pending, so a clean idle interface arms no tick and stays
//! inert until a key, a stream event, or a `.resize` marks it dirty again.
//!
//! The consumer-owned model and rendering — transcript, live tail, editor, view,
//! stats/model snapshots, and the `applyStreamEvent`/`paint` seam — live in
//! `Session`, which is io-, tty-, and agent-free so the render loop can be tested
//! from a scripted event sequence. `App` keeps only the io, tasks, tty, and agent
//! wiring and the key/command/turn orchestration that drives the `Session`.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Config = @import("Config.zig");
const Session = @import("Session.zig");

const App = @This();

const model = "claude-opus-4-8";
const model_info = ai.models.get(.anthropic, model) orelse
    @compileError("default model \"" ++ model ++ "\" is not in the model table");
const effort: ai.llm.Effort = .xhigh;
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
/// SIGWINCH watcher: turns terminal resizes into `.resize` events.
resize: terminal.Resize,
auth: ai.anthropic.Auth,
agent: ai.Agent,
/// The consumer-owned model and rendering, driven by the loop.
session: Session,
/// Decodes stdin chunks into key events for the consumer's key handling.
input: terminal.Input,
running: bool,
last_ctrl_c: i64,
/// The one cross-thread channel: producer tasks push `UiEvent`s, the consumer
/// drains and applies them. Backed by `queue_buffer`, so pin the `App`.
queue: std.Io.Queue(Session.UiEvent),
queue_buffer: [queue_capacity]Session.UiEvent,
/// The long-lived stdin reader task, or null before it is spawned; cancelled and
/// reaped at shutdown.
input_future: ?std.Io.Future(void),
/// The long-lived SIGWINCH watcher task, or null before it is spawned; cancelled
/// and reaped at shutdown.
resize_future: ?std.Io.Future(void),
/// The running turn worker, or null between turns.
turn_future: ?std.Io.Future(void),
/// The pending frame timer, or null when none is armed (idle or clean).
tick_future: ?std.Io.Future(void),
/// A frame timer is armed and its `.tick` has not been drained yet.
tick_pending: bool,
/// Monotonic time of the last paint, so the next tick lands one interval later.
last_paint_ms: i64,

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

    pub fn onThinking(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.app.queue.putOne(self.app.io, .{ .thinking = copy });
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

    pub fn onStreamReset(self: *TurnHandler) !void {
        try self.app.queue.putOne(self.app.io, .stream_reset);
    }

    pub fn onSteering(self: *TurnHandler, text: []const u8, count: usize) !void {
        const copy = try self.app.gpa.dupe(u8, text);
        errdefer self.app.gpa.free(copy);
        try self.app.queue.putOne(self.app.io, .{ .steering_consumed = .{ .text = copy, .count = count } });
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
    self.last_ctrl_c = 0;
    self.tick_pending = false;
    self.last_paint_ms = 0;
    self.input_future = null;
    self.resize_future = null;
    self.turn_future = null;
    self.tick_future = null;
    self.queue = std.Io.Queue(Session.UiEvent).init(&self.queue_buffer);

    const config = try Config.load(gpa, io, home);

    self.auth = try ai.anthropic.Auth.init(gpa, io, home);
    defer self.auth.deinit();
    try self.ensureAuth();

    const client = ai.provider.Client.init(gpa, io, .{ .anthropic_subscription = &self.auth }, config.timeouts);
    self.agent = ai.Agent.init(gpa, io, client, .{ .model = model_info, .system = system_prompt, .retry = config.retry, .effort = effort });
    defer self.agent.deinit();

    try self.tty.init(io);
    defer self.tty.deinit();

    try self.resize.init();
    defer self.resize.deinit();

    self.session = Session.init(gpa, self.tty.writer(), self.agent.model, self.agent.effort);
    defer self.session.deinit();
    self.input = terminal.Input.init(gpa);
    defer self.input.deinit();

    try self.session.transcript.append(.intro, false, intro_text);
    try self.refresh();
    self.last_paint_ms = self.nowMs();

    self.running = true;
    defer self.shutdownTasks();
    self.input_future = try self.io.concurrent(readInput, .{self});
    self.resize_future = try self.io.concurrent(readResize, .{self});

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
    if (self.input_future) |*future| {
        future.cancel(self.io);
        self.input_future = null;
    }
    if (self.resize_future) |*future| {
        future.cancel(self.io);
        self.resize_future = null;
    }
    if (self.tick_future) |*future| {
        future.cancel(self.io);
        self.tick_future = null;
    }
    self.drainQueue();
}

/// Free every event still buffered on the channel. Only safe once the producers
/// are reaped, so no new event can arrive mid-drain.
fn drainQueue(self: *App) void {
    var batch: [queue_capacity]Session.UiEvent = undefined;
    while (true) {
        const count = self.queue.get(self.io, &batch, 0) catch break;
        if (count == 0) break;
        for (batch[0..count]) |event| event.deinit(self.gpa);
    }
}

/// The consumer: block on the channel, drain a coalesced batch, apply each event
/// to the session, and paint only on a `.tick`. A tick is armed whenever the
/// session is dirty or a turn animates and none is pending, so a clean idle
/// interface stays inert (no tick, blocked on an empty channel).
fn runLoop(self: *App) !void {
    var batch: [queue_capacity]Session.UiEvent = undefined;
    while (self.running) {
        const count = self.queue.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed, error.Canceled => break,
        };
        var ticked = false;
        for (batch[0..count]) |event| switch (event) {
            .tick => ticked = true,
            .resize => self.session.dirty = true,
            .keys => |bytes| {
                defer self.gpa.free(bytes);
                try self.handleKeys(bytes);
            },
            else => try self.session.applyStreamEvent(event),
        };
        if (!self.session.animating()) {
            if (self.turn_future) |*future| {
                future.await(self.io);
                self.turn_future = null;
            }
            // A steering message that landed too late to fold into the turn just
            // ended opens the next turn on its own. Gating on the display mirror is
            // safe: `.steering_consumed` precedes `.turn_ended` in the channel, so
            // the mirror and the queue are in sync once the mode flips to prompt.
            if (self.session.mode == .prompt and !self.session.steeringEmpty())
                try self.startSteeringTurn();
        }
        if (ticked) {
            self.tick_pending = false;
            if (self.tick_future) |*future| {
                future.await(self.io);
                self.tick_future = null;
            }
            if (self.session.advanceFrame()) {
                try self.refresh();
                self.session.dirty = false;
                self.last_paint_ms = self.nowMs();
            }
        }
        if ((self.session.dirty or self.session.animating()) and !self.tick_pending) self.armTick();
    }
}

/// Arm the next frame: a one-shot timer that fires at `last_paint + interval`. On
/// the impossible failure to spawn it, paint inline so the frame is not lost.
fn armTick(self: *App) void {
    const elapsed = self.nowMs() - self.last_paint_ms;
    const delay_ms: i64 = if (elapsed >= frame_interval_ms) 0 else frame_interval_ms - elapsed;
    self.tick_future = self.io.concurrent(frameTimer, .{ self, delay_ms }) catch {
        self.refresh() catch {};
        self.session.dirty = false;
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

/// Resize watcher task: block on the SIGWINCH self-pipe and push one `.resize`
/// per wake, so the consumer repaints at the new size (which `refresh` re-reads).
/// Exits on cancel (shutdown) or a pipe fault.
fn readResize(self: *App) void {
    while (true) {
        self.resize.wait(self.io) catch return;
        self.queue.putOne(self.io, .resize) catch return;
    }
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
    switch (self.session.mode) {
        .picking => return self.handlePickerKey(event),
        .turn => return self.handleTurnKey(event),
        .prompt => {},
    }
    if (try self.editKey(event)) return;
    switch (event) {
        .enter => try self.submit(),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (self.running) self.session.markDirty();
            },
            'd' => if (self.session.editor.content().len == 0) {
                self.running = false;
            },
            else => {},
        },
        else => {},
    }
}

/// Apply an editing key to the live editor, marking the session dirty; returns
/// whether `event` was an editing key. Shared by the prompt and by a running
/// turn, where the editor stays live so the user can steer.
fn editKey(self: *App, event: terminal.Input.Key) !bool {
    const editor = &self.session.editor;
    switch (event) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .paste => |text| try editor.insert(text),
        .backspace => editor.backspace(),
        .left => editor.moveLeft(),
        .right => editor.moveRight(),
        .up => editor.moveUp(self.session.columns),
        .down => editor.moveDown(self.session.columns),
        .home => editor.moveHome(),
        .end => editor.moveEnd(),
        .newline => try editor.insert("\n"),
        .ctrl => |letter| switch (letter) {
            'j' => try editor.insert("\n"),
            else => return false,
        },
        else => return false,
    }
    self.session.markDirty();
    return true;
}

/// Keys during a streaming turn: the editor stays live for steering — typing and
/// editing work, Enter queues a steering message, Alt+Up recalls the queue into
/// the editor — while Esc or Ctrl+C cancels the turn.
fn handleTurnKey(self: *App, event: terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event) {
        .enter => try self.submitSteering(),
        .alt_up => try self.pullSteering(),
        .escape => try self.cancelTurn(),
        .ctrl => |letter| switch (letter) {
            'c' => try self.cancelTurn(),
            else => {},
        },
        else => {},
    }
}

/// Enter during a turn: queue the line as a steering message, shown at once and
/// carried to the worker to fold into the turn. A slash command can't run
/// mid-turn (it may open a picker, which a turn can't host), so it stays in the
/// editor to send once the turn ends.
fn submitSteering(self: *App) !void {
    const trimmed = std.mem.trim(u8, self.session.editor.content(), " \t\r\n");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "/")) return;
    const text = try self.gpa.dupe(u8, trimmed);
    defer self.gpa.free(text);
    // Channel first (the worker's source of truth), then the display mirror.
    try self.agent.steering.push(text);
    try self.session.queueSteering(text);
    self.session.editor.clear();
    self.session.markDirty();
}

/// Alt+Up during a turn: pull the whole steering queue back into the editor to
/// edit, appended after any in-progress line.
fn pullSteering(self: *App) !void {
    const joined = (try self.takeSteering()) orelse return;
    defer self.gpa.free(joined);
    try self.appendToEditor(joined);
    self.session.markDirty();
}

/// Take every not-yet-delivered steering message as one blank-line-joined
/// string, clearing the display mirror and the channel. Sourced from the channel
/// so a message the worker already folded into the running turn is not handed
/// back to the editor too (it will appear as a sent message instead). Null when
/// nothing is queued.
fn takeSteering(self: *App) !?[]u8 {
    self.session.clearSteering();
    const taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    if (taken.len == 0) return null;
    return try ai.Steering.join(self.gpa, taken);
}

/// Append `text` to the editor, after a blank-line separator when it already
/// holds an in-progress line.
fn appendToEditor(self: *App, text: []const u8) !void {
    const editor = &self.session.editor;
    editor.moveEnd();
    if (editor.content().len > 0) try editor.insert("\n\n");
    try editor.insert(text);
}

/// Start a turn from steering the worker never took because the previous turn
/// ended first: show it as a user message and run it.
fn startSteeringTurn(self: *App) !void {
    const joined = (try self.takeSteering()) orelse return;
    defer self.gpa.free(joined);
    try self.session.transcript.append(.user, false, joined);
    self.session.markDirty();
    try self.runTurn(joined);
}

/// Abort the running turn: cancel and reap the worker (interrupting its blocked
/// network read), then drop the turn's model state. Any events the worker already
/// queued are dropped when applied, since the mode is no longer a turn.
fn cancelTurn(self: *App) !void {
    // Cancel first (which joins the worker), so taking the queue can't race an
    // in-flight drain; nothing queued is lost — pending steering returns to the
    // editor.
    if (self.turn_future) |*future| {
        future.cancel(self.io);
        self.turn_future = null;
    }
    if (try self.takeSteering()) |joined| {
        defer self.gpa.free(joined);
        try self.appendToEditor(joined);
    }
    try self.session.abortTurn();
}

/// Ctrl+C: clear the editor, or quit when pressed twice inside the window.
fn clearOrQuit(self: *App) void {
    const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    if (now - self.last_ctrl_c < ctrl_c_window_ms) {
        self.running = false;
    } else {
        self.session.editor.clear();
        self.last_ctrl_c = now;
    }
}

/// Repaint: read the terminal size (keeping the last known one if the query
/// fails), then hand it to the session's projection. Reading size here is the
/// source of truth every frame; a `.resize` event just forces the frame so an
/// idle interface reflows too.
fn refresh(self: *App) !void {
    const size: terminal.View.Size = if (self.tty.size()) |window|
        .{ .columns = window.columns, .rows = window.rows }
    else
        .{ .columns = self.session.columns, .rows = self.session.rows };
    try self.session.paint(size);
}

/// Milliseconds on the monotonic clock, for frame scheduling.
fn nowMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

fn submit(self: *App) !void {
    const trimmed = std.mem.trim(u8, self.session.editor.content(), " \t\r\n");
    if (trimmed.len == 0) return;
    const text = try self.gpa.dupe(u8, trimmed);
    defer self.gpa.free(text);
    self.session.editor.clear();
    self.session.markDirty();

    if (std.mem.startsWith(u8, text, "/")) {
        try self.runCommand(text);
    } else {
        try self.session.transcript.append(.user, false, text);
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
    self.turn_future = try self.io.concurrent(runTurnWorker, .{ self, owned });
    self.session.beginTurn();
}

/// Handle a slash command locally, applying its outcome to the session.
fn runCommand(self: *App, line: []const u8) !void {
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    try self.session.applyOutcome(try ai.command.run(&context, line));
    self.session.model_shown = self.agent.model;
    self.session.effort_shown = self.agent.effort;
}

fn handlePickerKey(self: *App, event: terminal.Input.Key) !void {
    const picker = &self.session.mode.picking.picker;
    switch (event) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.session.cancelPicker(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.session.cancelPicker(),
            else => return,
        },
        else => return,
    }
    self.session.markDirty();
}

/// Re-apply the picker's command with the highlighted option as its argument.
fn confirmPicker(self: *App) !void {
    const picking = &self.session.mode.picking;
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    const outcome = try ai.command.apply(&context, picking.command, picking.picker.choice());
    self.session.closePicker();
    try self.session.applyOutcome(outcome);
    self.session.model_shown = self.agent.model;
    self.session.effort_shown = self.agent.effort;
}
