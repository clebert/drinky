//! The composition root and event loop. Authenticates, wires the tty, agent, and
//! `Session` together, then runs the interface off a single event channel:
//! producer tasks push `Session.UiEvent`s onto it and the consumer loop here
//! drains them, driving the `Session` model and painting through it.
//!
//! Network and stream I/O run off the UI thread. Four `io.concurrent` producers
//! feed one `std.Io.Queue(Session.UiEvent)`: a long-lived input reader
//! (stdin → `.keys`), the current turn worker (`agent.run` → generation-tagged
//! `.turn` events), a one-shot frame timer (sleep → `.tick`), and a SIGWINCH
//! watcher (self-pipe → `.resize`).
//!
//! The consumer-owned model and rendering — transcript, live tail, editor, view,
//! stats/model snapshots, and the `applyTurnEvent`/`paint` seam — live in
//! `Session`, which is io-, tty-, and agent-free so the render loop can be tested
//! from a scripted event sequence. `App` keeps only the io, tasks, tty, and agent
//! wiring and the key/command/turn orchestration that drives the `Session`.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Config = @import("Config.zig");
const Session = @import("Session.zig");

const App = @This();

// The compiled fallback model per vendor, used when config names none for the
// active account. Resolved at compile time so a bad name is a build error.
const anthropic_default = ai.models.get(.anthropic, "claude-opus-4-8") orelse
    @compileError("default anthropic model is not in the model table");
const openai_default = ai.models.get(.openai, "gpt-5.6-sol") orelse
    @compileError("default openai model is not in the model table");
const effort: ai.llm.Effort = .xhigh;
const system_prompt =
    "You are pith, a small coding assistant running in a terminal. Be concise. " ++
    "Explore the working directory with find (by name) and grep (literal text in " ++
    "file contents), read files with read, create or overwrite them with write, " ++
    "and change existing files with edit (give old_text that occurs exactly once).";

const intro_text = "pith — enter: send · shift+enter: newline · esc: cancel · " ++
    "ctrl+c: clear (twice: quit) · ctrl+d: quit";

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
accounts: ai.Accounts,
/// The configured default model per account, so switching accounts mid-session
/// (a `/model`, `/login`, or `/logout`) resolves the same model startup would.
default_models: Config.DefaultModels,
agent: ai.Agent,
/// The consumer-owned model and rendering, driven by the loop.
session: Session,
/// Decodes stdin chunks into key events for the consumer's key handling.
input: terminal.Input,
running: bool,
ctrl_c_ms_last: i64,
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
/// Last generation reserved for a turn worker. A generation is never reused.
turn_generation: u64,
/// The pending frame timer, or null when none is armed (idle or clean).
tick_future: ?std.Io.Future(void),
/// A frame timer is armed and its `.tick` has not been drained yet.
tick_pending: bool,
/// Monotonic time of the last paint, so the next tick lands one interval later.
paint_ms_last: i64,

/// The turn worker's presentation handler: instead of mutating the transcript, it
/// enqueues owned `UiEvent`s for the consumer. Lives on the worker thread, so it
/// touches only the thread-safe channel and gpa. `agent.run`'s `anytype` handler
/// makes this a drop-in for the consumer-side handler.
const TurnHandler = struct {
    app: *App,
    generation: u64,
    /// Owned error text captured from `onError`, which the agent calls just before
    /// a failed turn returns; the worker carries it into the single `.turn_ended`.
    error_text: ?[]u8 = null,

    pub fn onText(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .text = copy });
    }

    pub fn onThinking(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .thinking = copy });
    }

    pub fn onToolStart(self: *TurnHandler, name: []const u8, input_json: []const u8) !void {
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const json_copy = try self.app.gpa.dupe(u8, input_json);
        errdefer self.app.gpa.free(json_copy);
        try self.enqueue(.{ .tool_start = .{ .name = name_copy, .input_json = json_copy } });
    }

    pub fn onToolResult(
        self: *TurnHandler,
        name: []const u8,
        content: []const u8,
        is_error: bool,
    ) !void {
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const content_copy = try self.app.gpa.dupe(u8, content);
        errdefer self.app.gpa.free(content_copy);
        try self.enqueue(.{ .tool_result = .{
            .name = name_copy,
            .content = content_copy,
            .is_error = is_error,
        } });
    }

    pub fn onUsage(self: *TurnHandler, stats: ai.Agent.Stats) !void {
        try self.enqueue(.{ .usage = stats });
    }

    pub fn onStreamReset(self: *TurnHandler) !void {
        try self.enqueue(.stream_reset);
    }

    pub fn onSteering(self: *TurnHandler, text: []const u8, count: usize) !void {
        const copy = try self.app.gpa.dupe(u8, text);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .steering_consumed = .{ .text = copy, .count = count } });
    }

    pub fn onError(self: *TurnHandler, text: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, text);
        if (self.error_text) |old| self.app.gpa.free(old);
        self.error_text = copy;
    }

    fn enqueue(self: *TurnHandler, payload: Session.TurnEvent.Payload) !void {
        try self.app.queue.putOne(self.app.io, .{ .turn = .{
            .generation = self.generation,
            .payload = payload,
        } });
    }
};

/// Cooked-mode OAuth output keeps trusted prompt text separate from runtime URL
/// and path values, which pass through the terminal's inert-text policy.
const OauthPrompt = struct {
    writer: *std.Io.Writer,

    pub fn showAuthorization(self: *OauthPrompt, url: []const u8) !void {
        try self.writer.writeAll("Open this URL to authorize pith:\n\n");
        try self.writeText(url);
        try self.writer.writeAll("\n\nWaiting for the browser callback...\n");
        try self.writer.flush();
    }

    pub fn showBrowserLaunchFailed(self: *OauthPrompt) !void {
        try self.writer.writeAll(
            "Could not open a browser automatically; open the URL above manually.\n",
        );
        try self.writer.flush();
    }

    pub fn showAuthorized(self: *OauthPrompt, path: []const u8) !void {
        try self.writer.writeAll("Authorized. Credentials saved to ");
        try self.writeText(path);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    pub fn showSaveFailed(self: *OauthPrompt, path: []const u8, error_name: []const u8) !void {
        try self.writer.writeAll("Authorized, but saving credentials to ");
        try self.writeText(path);
        try self.writer.print(" failed ({s}); signed in until pith exits.\n", .{error_name});
        try self.writer.flush();
    }

    fn writeText(self: *OauthPrompt, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try self.writer.writeByte('\n');
            _ = try terminal.width.writeText(self.writer, line);
            first = false;
        }
    }
};

/// Wire up the tty, agent, and session, then run the interactive loop until the
/// user quits or stdin closes. When no account is authenticated the session
/// starts signed out and the login picker opens so the user signs in. Pin the
/// value: streams and the channel borrow its buffers.
pub fn run(
    self: *App,
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    api_keys: ai.Accounts.ApiKeys,
) !void {
    self.gpa = gpa;
    self.io = io;
    // The monotonic clock can start near zero; a boot press must never read as
    // the second of a pair.
    self.ctrl_c_ms_last = -ctrl_c_window_ms;
    self.tick_pending = false;
    self.paint_ms_last = 0;
    self.input_future = null;
    self.resize_future = null;
    self.turn_future = null;
    self.turn_generation = 0;
    self.tick_future = null;
    self.queue = std.Io.Queue(Session.UiEvent).init(&self.queue_buffer);

    const config = try Config.load(gpa, io, home);
    defer config.deinit(gpa);

    self.accounts = try ai.Accounts.init(gpa, io, home, config.timeouts, api_keys);
    defer self.accounts.deinit();
    self.default_models = config.default_models;

    // Start on the first authenticated account, or signed out (no client) when
    // none is — the login picker opens below to sign in. The model is resolved
    // for the chosen or placeholder account either way, so the status line has one
    // to show.
    const active = self.accounts.firstAuthenticated();
    const start_account = active orelse .anthropic_subscription;
    const start_client = if (active) |account| self.accounts.client(account) else null;
    self.agent = ai.Agent.init(gpa, io, start_client, .{
        .model = self.defaultModel(start_account),
        .system = system_prompt,
        .retry = config.retry,
        .effort = effort,
    });
    defer self.agent.deinit();

    try self.tty.init(io);
    defer self.tty.deinit();

    try self.resize.init();
    defer self.resize.deinit();

    self.session = Session.init(gpa, self.tty.writer(), self.agent.model, self.agent.effort);
    defer self.session.deinit();
    self.session.signed_in = self.signedIn();
    self.input = terminal.Input.init(gpa);
    defer self.input.deinit();

    try self.session.transcript.append(.intro, false, intro_text);
    // Surface any configured default-model name that did not resolve, so a typo or
    // wrong-vendor entry is not silently ignored.
    for (config.dropped_defaults) |dropped| try self.report(
        .err,
        "config: default model \"{s}\" is not a valid model for {s}; using {s}",
        .{ dropped.name, dropped.account.label(), self.defaultModel(dropped.account).name },
    );
    // No account signed in: open the login picker (the same one /login opens) so
    // the user chooses how to sign in.
    if (!self.signedIn()) {
        try self.report(.ok, "no account is signed in — choose one to log in", .{});
        try self.runCommand("/login");
    }
    try self.refresh();
    self.paint_ms_last = self.nowMs();

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
    self.cancelFuture(&self.turn_future);
    self.cancelFuture(&self.input_future);
    self.cancelFuture(&self.resize_future);
    self.cancelFuture(&self.tick_future);
    self.drainQueue();
}

/// Cancel and reap `maybe_future`'s task, clearing the handle; a no-op when null.
fn cancelFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.cancel(self.io);
        maybe_future.* = null;
    }
}

/// Reap `maybe_future`'s finished task, clearing the handle; a no-op when null.
fn awaitFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.await(self.io);
        maybe_future.* = null;
    }
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
        const ticked = try self.applyBatch(batch[0..count]);
        if (!self.session.animating()) {
            self.awaitFuture(&self.turn_future);
            // A steering message that landed too late to fold into the turn just
            // ended opens the next turn on its own. Consumed events precede
            // `.turn_ended`, while failed delivery restores its plain queue prefix
            // before the worker ends; the matching rich drafts remain retained.
            if (self.session.mode == .prompt and self.session.hasSteering())
                try self.startSteeringTurn();
        }
        if (ticked) {
            self.tick_pending = false;
            self.awaitFuture(&self.tick_future);
            if (self.session.advanceFrame()) {
                try self.refresh();
                self.session.dirty = false;
                self.paint_ms_last = self.nowMs();
            }
        }
        if ((self.session.dirty or self.session.animating()) and !self.tick_pending) self.armTick();
    }
}

/// Apply one bounded queue batch. Once the queue hands the batch to the consumer,
/// this function owns every event; an error frees the unprocessed suffix.
fn applyBatch(self: *App, events: []const Session.UiEvent) !bool {
    std.debug.assert(events.len <= queue_capacity);
    var applied_count: usize = 0;
    errdefer for (events[applied_count..]) |event| event.deinit(self.gpa);

    var ticked = false;
    for (events) |*event| {
        applied_count += 1;
        switch (event.*) {
            .tick => ticked = true,
            .resize => self.session.dirty = true,
            .keys => |bytes| {
                defer self.gpa.free(bytes);
                try self.handleKeys(bytes);
            },
            .turn => |*turn_event| {
                try self.session.applyTurnEvent(turn_event);
                // Start late steering at the turn boundary before a later key in
                // this same drained batch can submit a newer prompt first.
                if (self.session.mode == .prompt and self.session.hasSteering())
                    try self.startSteeringTurn();
            },
        }
    }
    return ticked;
}

/// Arm the next frame: a one-shot timer that fires at `last_paint + interval`. On
/// the impossible failure to spawn it, paint inline so the frame is not lost.
fn armTick(self: *App) void {
    const elapsed = self.nowMs() - self.paint_ms_last;
    const delay_ms: i64 = if (elapsed >= frame_interval_ms) 0 else frame_interval_ms - elapsed;
    self.tick_future = self.io.concurrent(frameTimer, .{ self, delay_ms }) catch {
        self.refresh() catch {};
        self.session.dirty = false;
        self.paint_ms_last = self.nowMs();
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
/// `.turn_ended` (carrying any error text). Cancellation suppresses that final
/// event; any output queued before cancellation remains consumer-owned and tagged
/// with this worker's generation. `agent.run` rolls its items back on error.
fn runTurnWorker(self: *App, text: []const u8, generation: u64) void {
    defer self.gpa.free(text);
    var handler: TurnHandler = .{ .app = self, .generation = generation };
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
    handler.enqueue(.{ .turn_ended = handler.error_text }) catch {
        if (handler.error_text) |extra| self.gpa.free(extra);
    };
}

/// Whether an account is active (the agent has a client). False leaves the
/// session signed out — normal messages are refused until a login.
fn signedIn(self: *const App) bool {
    return self.agent.client != null;
}

/// The model to start `account` on: the configured default, else the compiled
/// per-vendor fallback.
fn defaultModel(self: *const App, account: ai.llm.Account) ai.models.Model {
    const base = self.default_models.get(account) orelse switch (account.provider()) {
        .anthropic => anthropic_default,
        .openai => openai_default,
    };
    return self.accounts.resolveModel(account, base);
}

/// Decode a stdin chunk into key events and apply each. Runs on the consumer, so
/// a submitted line spawns a turn worker and ctrl-c cancels a running one.
fn handleKeys(self: *App, bytes: []const u8) !void {
    try self.input.feed(bytes);
    while (self.input.next()) |event| try self.handleKey(&event);
}

fn handleKey(self: *App, event: *const terminal.Input.Key) !void {
    switch (self.session.mode) {
        .picking => return self.handlePickerKey(event),
        .turn => return self.handleTurnKey(event),
        .prompt => {},
    }
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submit(),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (self.running) self.session.dirty = true;
            },
            'd' => if (self.session.editor.visible().len == 0) {
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
fn editKey(self: *App, event: *const terminal.Input.Key) !bool {
    const editor = &self.session.editor;
    switch (event.*) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
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
    self.session.dirty = true;
    return true;
}

/// Keys during a streaming turn: the editor stays live for steering — typing and
/// editing work, Enter queues a steering message, Alt+Up recalls the queue into
/// the editor — while Esc or Ctrl+C cancels the turn.
fn handleTurnKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
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
    if (self.session.editor.blank()) return;
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    if (std.mem.startsWith(u8, text, "/")) return;
    // Reserve the mirror slot before the channel push, so the push is the only
    // fallible step before the draft moves in: if it fails the editor is
    // untouched, and once it succeeds the literal-edge-trimmed draft moves into
    // the mirror without allocating. The channel copy is whole-prompt trimmed; the
    // recovery draft keeps its atoms and their exact payloads.
    try self.session.reserveSteering();
    try self.agent.steering.push(text);
    var draft = self.session.editor.detachTrimmed();
    self.session.commitSteeringDraft(&draft);
    self.session.dirty = true;
}

/// Alt+Up during a turn: pull the pending steering back into the editor as live
/// placeholder drafts, after any in-progress line. Content comes from the mirror
/// (so a paste returns as its marker, not expanded text); the channel gives only
/// the count selecting the mirror's pending suffix. The remaining prefix stays
/// retained until consumed or made recallable by failed delivery.
fn pullSteering(self: *App) !void {
    // Reserve every possible draft move so no fallible work follows the channel
    // take.
    try self.session.reserveSteeringRecall();
    const taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    // The count identifies the rich-record suffix currently owned by the queue;
    // a batch already owned by the worker remains retained.
    self.session.recallSteering(taken.len);
}

/// Start a turn from steering the worker never took because the previous turn
/// ended first. Keep both plain and rich forms recoverable until the transcript
/// block and worker have committed; this path intentionally flattens atoms.
fn startSteeringTurn(self: *App) !void {
    var taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    errdefer self.agent.steering.restoreTaken(&taken);
    if (taken.len == 0) {
        self.session.clearSteering();
        return;
    }

    const joined = try ai.Steering.join(self.gpa, taken);
    defer self.gpa.free(joined);
    const transcript_count = self.session.transcript.blocks().len;
    errdefer self.session.transcript.truncate(transcript_count);
    try self.session.transcript.append(.user, false, joined);
    self.session.dirty = true;
    try self.runTurn(joined);
    self.session.clearSteering();
}

/// Abort the running turn: cancel and reap the worker (interrupting its blocked
/// network read), then drop the turn's model state. Events the worker already
/// queued retain its generation and cannot affect a successor.
fn cancelTurn(self: *App) !void {
    // Preflight the only allocation needed for restoration while the worker and
    // turn are still untouched. The mirror is consumer-owned and stable here.
    try self.session.reserveSteeringRestore();
    self.cancelFuture(&self.turn_future);
    // A final `.usage` still queued dies at the generation gate; the worker is
    // joined, so the cumulative stats are safe to read and resync here.
    self.session.stats_shown = self.agent.stats;
    // Restore rich drafts before any further fallible work. A message folded just
    // before cancel is rolled back agent-side while its consumed event becomes
    // stale, so only these records can recover it.
    self.session.restoreSteering();
    // The worker is joined, so allocation-free clearing cannot race a re-push.
    self.agent.steering.clear();
    // This may fail while allocating the feedback block, but cancellation and
    // steering restoration are already complete and internally consistent.
    try self.session.abortTurn();
}

/// Ctrl+C: clear the editor, or quit when pressed twice inside the window.
/// Measured on the monotonic clock — a wall-clock step must not fake or break
/// the double press.
fn clearOrQuit(self: *App) void {
    const now = self.nowMs();
    if (now - self.ctrl_c_ms_last < ctrl_c_window_ms) {
        self.running = false;
    } else {
        self.session.editor.clear();
        self.ctrl_c_ms_last = now;
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
    if (self.session.editor.blank()) return;
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    self.session.editor.clear();
    self.session.dirty = true;

    if (std.mem.startsWith(u8, text, "/")) {
        try self.runCommand(text);
    } else if (!self.signedIn()) {
        try self.report(.err, "not signed in — use /login to sign in", .{});
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
    self.awaitFuture(&self.turn_future);
    const generation = try self.reserveTurnGeneration();
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    self.turn_future = try self.io.concurrent(runTurnWorker, .{ self, owned, generation });
    self.session.beginTurn(generation);
}

/// Permanently reserve the next turn generation before a worker can observe it.
/// Failed allocation or spawn may leave a gap, but no generation is reused.
fn reserveTurnGeneration(self: *App) !u64 {
    if (self.turn_generation == std.math.maxInt(u64)) return error.TurnGenerationExhausted;
    self.turn_generation += 1;
    return self.turn_generation;
}

/// Handle a slash command locally, applying its outcome.
fn runCommand(self: *App, line: []const u8) !void {
    var context: ai.command.Context =
        .{ .gpa = self.gpa, .agent = &self.agent, .accounts = &self.accounts };
    try self.applyOutcome(try ai.command.run(&context, line));
}

/// Apply a command outcome: account actions (`/login`, `/logout`) need the tty
/// and the agent, so the app runs them; everything else the session shows.
fn applyOutcome(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .login => |account| try self.loginAccount(account),
        .logout => |account| try self.logoutAccount(account),
        .switch_account => |account| {
            self.adopt(account);
            try self.report(.ok, "switched to {s} ({s})", .{
                self.agent.model.name,
                account.label(),
            });
        },
        else => try self.session.applyOutcome(outcome),
    }
    self.session.model_shown = self.agent.model;
    self.session.effort_shown = self.agent.effort;
    self.session.signed_in = self.signedIn();
}

/// Log in to a subscription `account`, then switch to it on its default model.
/// A failed login leaves the current account untouched.
fn loginAccount(self: *App, account: ai.llm.Account) !void {
    return self.finishLogin(account, self.runOauth(account));
}

fn finishLogin(self: *App, account: ai.llm.Account, result: anyerror!void) !void {
    result catch |err| {
        const message = switch (err) {
            error.Canceled => return error.Canceled,
            error.CallbackTimeout => "login timed out waiting for the browser callback",
            error.CallbackRequestTooLarge => "login failed: browser callback request was too large",
            error.CallbackTimeoutUnavailable => "login failed: browser callback deadline " ++
                "was unavailable",
            else => return self.report(.err, "login failed: {s}", .{@errorName(err)}),
        };
        return self.report(.err, "{s}", .{message});
    };
    self.adopt(account);
    try self.report(.ok, "logged in to {s}; using {s}", .{
        account.label(),
        self.agent.model.name,
    });
}

/// Drop a subscription `account`'s credentials. Logging out the active account
/// hands the session to the next authenticated account (its default model), or —
/// when none remains — drops to a signed-out state and opens the login picker so
/// the user chooses how to sign back in. Commands cannot run mid-turn, so this
/// never races a turn.
fn logoutAccount(self: *App, account: ai.llm.Account) !void {
    const was_active = if (self.agent.client) |client| client.account() == account else false;
    self.accounts.logout(account) catch |err| {
        return self.report(.err, "logout failed: {s}", .{@errorName(err)});
    };
    if (!was_active)
        return self.report(.ok, "logged out of {s}", .{account.label()});
    if (self.accounts.firstAuthenticated()) |next| {
        self.adopt(next);
        return self.report(.ok, "logged out of {s}; switched to {s} ({s})", .{
            account.label(),
            self.agent.model.name,
            next.label(),
        });
    }
    // No account remains: sign out and let the user choose from the login picker —
    // no forced browser, no loop.
    self.agent.signOut();
    try self.report(.ok, "logged out of {s}; no account is signed in — choose one to log in", .{
        account.label(),
    });
    // Through the session, not `runCommand`: routing back through `applyOutcome`
    // would cycle the inferred error sets (runCommand → applyOutcome → here).
    var context: ai.command.Context =
        .{ .gpa = self.gpa, .agent = &self.agent, .accounts = &self.accounts };
    try self.session.applyOutcome(try ai.command.run(&context, "/login"));
}

/// Run an account's interactive OAuth flow, suspending the raw-mode interface
/// around it so the URL prints cleanly and the browser callback can complete,
/// then restoring raw mode and forcing a full repaint. The blocked input reader
/// touches only stdin, so it does not interfere.
fn runOauth(self: *App, account: ai.llm.Account) !void {
    self.tty.leaveRaw();
    defer {
        self.tty.enterRaw() catch {};
        self.session.view.invalidate();
        self.session.dirty = true;
    }
    var prompt: OauthPrompt = .{ .writer = self.tty.writer() };
    try self.accounts.login(account, &prompt);
}

/// Switch the agent to `account` on its default model. The client is present
/// because the caller just authenticated the account or read it from the registry.
fn adopt(self: *App, account: ai.llm.Account) void {
    self.agent.switchTo(self.accounts.client(account).?, self.defaultModel(account));
}

/// Show one feedback line in the transcript.
fn report(
    self: *App,
    status: ai.command.Outcome.Status,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.session.applyOutcome(try ai.command.Outcome.report(self.gpa, status, format, args));
}

fn handlePickerKey(self: *App, event: *const terminal.Input.Key) !void {
    const picker = &self.session.mode.picking.picker;
    switch (event.*) {
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
    self.session.dirty = true;
}

/// Apply the highlighted picker row through its command's selection handler.
fn confirmPicker(self: *App) !void {
    const picking = &self.session.mode.picking;
    var context: ai.command.Context =
        .{ .gpa = self.gpa, .agent = &self.agent, .accounts = &self.accounts };
    const outcome = try picking.select(&context, picking.picker.cursor);
    self.session.closePicker();
    try self.applyOutcome(outcome);
}

test "OAuth prompts render runtime fields as inert text" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var prompt: OauthPrompt = .{ .writer = &out.writer };

    try prompt.showAuthorization("https://example.test/\x1b]52;c;b3duZWQ=\x07");
    try prompt.showBrowserLaunchFailed();
    try prompt.showAuthorized("/home/\x1b[2J/.pith/auth.json");
    try prompt.showSaveFailed("/home/\x1b[2J/.pith/auth.json", "AccessDenied");

    const written = out.written();
    const url_inert = "https://example.test/\u{200B}�\u{200B}]52;c;b3duZWQ=\u{200B}�\u{200B}";
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]52;c;b3duZWQ=\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, url_inert) != null);
    const path_inert = "/home/\u{200B}�\u{200B}[2J/.pith/auth.json";
    try std.testing.expect(std.mem.indexOf(u8, written, path_inert) != null);
}

test "OAuth login cancellation escapes without failure feedback" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const block_count = app.session.transcript.blocks().len;
    try std.testing.expectError(
        error.Canceled,
        app.finishLogin(.anthropic_subscription, error.Canceled),
    );
    try std.testing.expectEqual(block_count, app.session.transcript.blocks().len);
}

test "OAuth callback bounds have friendly failure feedback" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const cases = [_]struct { anyerror, []const u8 }{
        .{ error.CallbackTimeout, "login timed out waiting for the browser callback" },
        .{ error.CallbackRequestTooLarge, "login failed: browser callback request was too large" },
        .{
            error.CallbackTimeoutUnavailable,
            "login failed: browser callback deadline was unavailable",
        },
    };
    for (cases, 0..) |case, index| {
        const failure, const message = case;
        try app.finishLogin(.anthropic_subscription, failure);
        const feedback = app.session.transcript.blocks()[index].feedback;
        try std.testing.expect(feedback.is_error);
        try std.testing.expectEqualStrings(message, feedback.text.items);
    }
}

test "turn producers keep their captured generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const generation: u64 = 42;

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.queue = std.Io.Queue(Session.UiEvent).init(&app.queue_buffer);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();

    var handler: TurnHandler = .{ .app = &app, .generation = generation };
    try handler.onText("text");
    try handler.onThinking("thinking");
    try handler.onToolStart("read", "{}");
    try handler.onToolResult("read", "result", false);
    try handler.onUsage(.{});
    try handler.onStreamReset();
    try handler.onSteering("steer", 1);
    runTurnWorker(&app, try gpa.dupe(u8, "prompt"), generation);

    var events: [8]Session.UiEvent = undefined;
    const count = try app.queue.get(io, &events, events.len);
    defer for (events[0..count]) |event| event.deinit(gpa);
    try std.testing.expectEqual(events.len, count);
    for (events[0..count]) |event| switch (event) {
        .turn => |turn_event| try std.testing.expectEqual(generation, turn_event.generation),
        else => return error.UnexpectedEvent,
    };
    switch (events[events.len - 1].turn.payload) {
        .turn_ended => |maybe_text| try std.testing.expectEqualStrings("SignedOut", maybe_text.?),
        else => return error.UnexpectedEvent,
    }
}

// Queue a plain-text (atom-free) steering draft directly on the mirror, standing
// in for a message the worker already folded (so the channel no longer holds it).
// Built through the real editor detach path the app uses.
fn seedSteering(app: *App, text: []const u8) !void {
    try app.session.editor.insert(text);
    try app.session.reserveSteering();
    var draft = app.session.editor.detachTrimmed();
    app.session.commitSteeringDraft(&draft);
}

test "a failed late-steering turn start restores queue, mirror, and transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.turn_generation = std.math.maxInt(u64);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.agent.steering.push("late");
    try seedSteering(&app, "late");
    try std.testing.expectError(error.TurnGenerationExhausted, app.startSteeringTurn());
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.session.hasSteering());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);

    const restored = try app.agent.steering.take();
    defer {
        for (restored) |message| gpa.free(message);
        gpa.free(restored);
    }
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    try std.testing.expectEqualStrings("late", restored[0]);
}

test "cancelling a turn joins and clears its active worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    var started: std.atomic.Value(bool) = .init(false);
    var stopped: std.atomic.Value(bool) = .init(false);
    const work = struct {
        const State = struct {
            ready: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
        };

        fn wait(worker_io: std.Io, state: State) void {
            state.ready.store(true, .release);
            defer state.done.store(true, .release);
            worker_io.sleep(.fromSeconds(60), .awake) catch {};
        }
    };
    app.turn_future = try io.concurrent(work.wait, .{ io, work.State{
        .ready = &started,
        .done = &stopped,
    } });
    defer if (app.turn_future) |*future| future.cancel(io);

    var poll: usize = 0;
    while (!started.load(.acquire) and poll < 1000) : (poll += 1)
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    try std.testing.expect(started.load(.acquire));

    try app.cancelTurn();
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(stopped.load(.acquire));
    try std.testing.expect(app.session.mode == .prompt);
}

// The race a cancel must survive: the worker folded a pasted message (channel
// entry taken, `.steering_consumed` still queued, so only the mirror holds it)
// while a newer message is pending in both. Everything returns to the editor
// exactly once, and queued usage is resynced from the joined agent.
test "cancelling a turn restores in-flight steering and resyncs usage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 10 ++ "line";
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    try app.session.editor.insert("and Y");
    try app.submitSteering();
    app.agent.stats.cost = 1.5;

    try app.cancelTurn();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload ++ "\n\nand Y", expanded);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(f64, 1.5), app.session.stats_shown.cost);
    try std.testing.expect(app.session.mode == .prompt);
}

test "cancel preflight failure leaves the turn and steering untouched" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("restore me");
    try app.submitSteering();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try app.cancelTurn();
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("restore me", app.session.editor.visible());
}

test "cancel restores steering before feedback allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("restore me");
    try app.submitSteering();
    try app.session.editor.reserveDrafts(app.session.steering.items);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("restore me", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const taken = try app.agent.steering.take();
    defer gpa.free(taken);
    try std.testing.expectEqual(@as(usize, 0), taken.len);
}

test "alt+up recalls the steering queue after in-progress editor text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("fix it");
    try app.submitSteering();
    try app.session.editor.insert("and test");
    try app.submitSteering();
    try app.session.editor.insert("draft");

    try app.pullSteering();
    try std.testing.expectEqualStrings("draft\n\nfix it\n\nand test", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
}

test "alt+up restores a steered paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15; // 16 logical lines: collapses to a marker
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 1), app.session.editor.draft.atoms.items[0].id);
    try std.testing.expect(
        std.mem.indexOf(u8, app.session.editor.visible(), "[paste #1 +16 lines]") != null,
    );
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

// Cancel restores a worker-owned paste whose consumed event is still pending.
// A later stale event cannot remove the restored atom, and payload-edge
// whitespace survives because the draft is only literal-edge trimmed.
test "cancel restores an in-flight steered paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    const folded = try app.agent.steering.take();
    try std.testing.expectEqual(@as(usize, 1), folded.len);
    try std.testing.expectEqualStrings(delivered, folded[0]);
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    try app.cancelTurn();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expect(app.session.mode == .prompt);
    try app.session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, delivered),
            .count = 1,
        } },
    });
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

test "cancel does not restore a steered paste after its consumed event applied" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    try std.testing.expectEqual(@as(usize, 1), folded.len);
    try std.testing.expectEqualStrings(delivered, folded[0]);
    for (folded) |message| gpa.free(message);
    gpa.free(folded);
    try app.session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, delivered),
            .count = 1,
        } },
    });

    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try app.cancelTurn();
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqualStrings(delivered, app.session.transcript.blocks()[0].user.items);
}

// Alt+Up recalls only the pending suffix; the already folded prefix stays rich
// but hidden until its consumed event applies or failed delivery requeues it.
test "alt+up recalls the pending suffix and retains the in-flight prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    // "folded": the worker took it, so only the mirror holds it (in-flight prefix).
    try seedSteering(&app, "folded");
    // "pending": still queued in both the channel and the mirror.
    try app.session.editor.insert("pending");
    try app.submitSteering();
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);

    try app.pullSteering();
    try std.testing.expectEqualStrings("pending", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);
}

test "cancel restores an in-flight prefix retained by alt+up" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try seedSteering(&app, "folded");
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);

    try app.cancelTurn();
    try std.testing.expectEqualStrings("folded", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering_retained_count);
    try std.testing.expect(app.session.mode == .prompt);
}

test "a delayed consumed event after alt+up cannot remove newer steering" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("old");
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    // The worker owns "old", but its consumed event has not reached the UI.
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);
    try app.session.editor.insert("new");
    try app.submitSteering();

    try app.session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, "old"),
            .count = 1,
        } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.session.steering_retained_count);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("new", app.session.steering.items[0].visible.items);

    try app.pullSteering();
    try std.testing.expectEqualStrings("new", app.session.editor.visible());
}

test "a delivery restored after alt+up recalls its retained rich drafts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("a");
    try app.submitSteering();
    try app.session.editor.insert("b");
    try app.submitSteering();
    var delivery = try app.agent.steering.take();
    defer {
        for (delivery) |message| gpa.free(message);
        gpa.free(delivery);
    }

    // The first recall sees the batch as in flight and retains its rich drafts.
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.session.steering_retained_count);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    // Failed delivery returns the plain batch. A later recall selects the
    // matching retained suffix and moves it back live.
    app.agent.steering.restoreTaken(&delivery);
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering_retained_count);
    try std.testing.expectEqualStrings("a\n\nb", app.session.editor.visible());
}

// Literal-edge canonicalization: separately submitted " a " and " b " recall and
// rejoin as "a\n\nb", never reviving the trimmed edge spaces.
test "recall of literal-edge-trimmed steering rejoins without edge spaces" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert(" a ");
    try app.submitSteering();
    try app.session.editor.insert(" b ");
    try app.submitSteering();
    try app.pullSteering();
    try std.testing.expectEqualStrings("a\n\nb", app.session.editor.visible());
}

// A slash command can't run mid-turn, so Enter must leave it in the editor to
// send once the turn ends, never queue it as prompt text for the model.
test "a mid-turn slash command or blank line is never queued as steering" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("/model");
    try app.submitSteering();
    try std.testing.expectEqualStrings("/model", app.session.editor.visible());

    app.session.editor.clear();
    try app.session.editor.insert("   ");
    try app.submitSteering();
    try std.testing.expectEqualStrings("   ", app.session.editor.visible());

    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    const taken = try app.agent.steering.take();
    defer gpa.free(taken);
    try std.testing.expectEqual(@as(usize, 0), taken.len);
}

test "late placeholder steering flattens before a newer key in the same batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.input = terminal.Input.init(gpa);
    defer app.input.deinit();
    app.queue = std.Io.Queue(Session.UiEvent).init(&app.queue_buffer);
    defer app.drainQueue();
    app.turn_future = null;
    defer app.cancelFuture(&app.turn_future);
    app.turn_generation = 1;
    app.session.beginTurn(1);

    const payload = "line\n" ** 10 ++ "line";
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    const events = [_]Session.UiEvent{
        .{ .turn = .{ .generation = 1, .payload = .{ .turn_ended = null } } },
        .{ .keys = try gpa.dupe(u8, "new\r") },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqualStrings(payload, app.session.transcript.blocks()[0].user.items);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("new", app.session.steering.items[0].visible.items);
}

// The lifecycle calls model cancellation and resubmission key entries from a
// batch App already drained; the remaining entries use the real outer queue union
// and batch dispatcher.
test "a drained batch routes only the active turn generation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    app.session.beginTurn(1);
    const first = [_]Session.UiEvent{.{ .turn = .{
        .generation = 1,
        .payload = .{ .text = try gpa.dupe(u8, "turn A") },
    } }};
    try std.testing.expect(!try app.applyBatch(&first));
    try app.session.abortTurn();
    app.session.beginTurn(2);

    const rest = [_]Session.UiEvent{
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .text = try gpa.dupe(u8, "stale A") },
        } },
        .{ .turn = .{ .generation = 1, .payload = .{ .turn_ended = null } } },
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .turn_ended = try gpa.dupe(u8, "turn A failed") },
        } },
        .{ .turn = .{
            .generation = 2,
            .payload = .{ .text = try gpa.dupe(u8, "turn B") },
        } },
        .{ .turn = .{ .generation = 2, .payload = .{ .turn_ended = null } } },
    };
    try std.testing.expect(!try app.applyBatch(&rest));

    try std.testing.expect(!app.session.animating());
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings("turn B", app.session.transcript.blocks()[2].model.items);
}

// A resize marks the model dirty without ticking, so even an idle interface
// reflows on the next frame.
test "a resize event marks an idle interface dirty" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try std.testing.expect(!try app.applyBatch(&[_]Session.UiEvent{.resize}));
    try std.testing.expect(app.session.dirty);
}

test "a failed batch frees its unprocessed turn events" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const events = [_]Session.UiEvent{
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .text = try gpa.dupe(u8, "current") },
        } },
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .text = try gpa.dupe(u8, "unprocessed") },
        } },
    };
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, app.applyBatch(&events));
}

test "turn generations cannot wrap or be reused" {
    var app: App = undefined;
    app.turn_generation = std.math.maxInt(u64);

    try std.testing.expectError(error.TurnGenerationExhausted, app.reserveTurnGeneration());
    try std.testing.expectEqual(std.math.maxInt(u64), app.turn_generation);
}

test "ctrl+c clears then quits within the window and ctrl+d quits only when empty" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = std.testing.io;
    app.ctrl_c_ms_last = -ctrl_c_window_ms;
    app.running = true;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.editor.insert("draft");
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.running);

    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.running);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(!app.running);

    app.running = true;
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);
}

// Signed out, a normal message must be refused with a /login prompt rather
// than spawn a turn against no client.
test "a signed-out submit is refused with a login prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.editor.insert("hello");
    try app.submit();

    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].feedback.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].feedback.text.items, "/login") != null);
}

// A large paste that expands to a slash command is classified from its expanded
// text, never its marker label, and the label never reaches command dispatch.
test "a large pasted slash command is classified from expanded text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    // Twelve lines beginning with "/nope": large enough to collapse to a marker.
    try app.session.editor.paste("/nope\n" ** 11 ++ "/nope", true);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);

    try app.submit();

    // The command ran off the expanded "/nope", not the "[paste …]" label.
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].feedback.is_error);
    const feedback = blocks[0].feedback.text.items;
    try std.testing.expect(std.mem.indexOf(u8, feedback, "unknown command: /nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, feedback, "paste") == null);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
}

test "esc, ctrl+c, and ctrl+d each dismiss the picker as cancelled" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const keys = [_]terminal.Input.Key{ .escape, .{ .ctrl = 'c' }, .{ .ctrl = 'd' } };
    for (keys, 0..) |key, index| {
        const options = try gpa.alloc([]const u8, 1);
        options[0] = try gpa.dupe(u8, "alpha");
        try app.session.applyOutcome(.{
            .pick = .{
                // Never called: every key under test cancels.
                .select = undefined,
                .title = "Log in",
                .options = options,
                .current = null,
            },
        });
        try app.handlePickerKey(&key);
        try std.testing.expect(app.session.mode == .prompt);
        const feedback = app.session.transcript.blocks()[index].feedback;
        try std.testing.expect(!feedback.is_error);
        try std.testing.expectEqualStrings("cancelled", feedback.text.items);
    }
}
